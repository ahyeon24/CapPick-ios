import Foundation
import Tokenizers
import OnnxRuntimeBindings

enum OnnxEmbeddingError: Error, Equatable {
    /// 앱 번들에 모델/토크나이저 자산이 없거나 로드에 실패했을 때.
    case modelUnavailable(String)
    case emptyText
}

/// E5 계열 모델은 검색어와 색인 대상 텍스트를 서로 다른 접두어로 구분해서 임베딩한다
/// (모델 카드의 공식 사용법 — 접두어 없이 넣으면 품질이 떨어진다).
enum OnnxEmbeddingInputKind {
    case query
    case passage
}

/// 온디바이스 검색 전환 Phase 2, `NLContextualEmbedding` 대신 채택한 경로.
/// `intfloat/multilingual-e5-small`(MIT, 384차원)을 ONNX Runtime Mobile로 직접 실행한다 —
/// 시뮬레이터 전용 버그로 검증 자체가 막혔던 `NLContextualEmbedding`과 달리, 앱 번들에 들어있는
/// 고정된 모델 파일을 쓰므로 OS 에셋 다운로드·플랫폼별 모델 버전 문제가 없다. Android에서도 같은
/// `.onnx` 파일을 ONNX Runtime Mobile로 돌리면 커널 차이 없이 동일한 벡터가 나온다는 게
/// 크로스플랫폼 후보 비교에서 이 접근을 고른 이유였다(NLContextualEmbedding.md 조사 결과 참고).
///
/// 모델은 `CapPick/Resources/E5Small/`에 번들로 포함한다(`model_quantized.onnx` 약 113MB,
/// `tokenizer.json`/`tokenizer_config.json`) — Xenova/multilingual-e5-small의 int8 동적
/// 양자화 버전을 썼다. intfloat 원본 저장소의 `onnx/model_qint8_avx512_vnni.onnx`는 이름 그대로
/// Intel AVX512-VNNI 전용으로 양자화된 그래프라 ARM(iOS/Android 둘 다)에서 쓰기에 위험 부담이
/// 있어 피했다 — Xenova 버전은 브라우저(WASM) 실행을 전제로 하드웨어 독립적으로 양자화돼 있다.
///
/// 모델은 BERT 계열 인코더라 `input_ids`/`attention_mask`/`token_type_ids` 3개를 받고
/// `last_hidden_state`([1, seq_len, 384])만 내놓는다(pooler_output 없음) — 그래서 이 서비스가
/// 토큰 평균(mean pooling, attention_mask 가중)과 L2 정규화를 직접 한다(모델 카드의 공식
/// average_pool 사용법과 동일). 이 서비스는 한 번에 텍스트 하나만 처리해서(배치 없음) 패딩이
/// 필요 없다 — attention_mask는 항상 전부 1이다.
actor OnnxEmbeddingService {
    /// 번들에 고정으로 들어있는 자산이라 OS가 갱신할 수 있는 `NLContextualEmbedding`과 달리
    /// 고정 문자열로 둔다 — 이 서비스가 만드는 벡터의 공간이 바뀌는 유일한 경우는 번들 자산을
    /// 다른 버전으로 교체하며 이 상수도 같이 올릴 때뿐이다.
    static let modelVersion = "multilingual-e5-small-quantized-1"

    private static let resourceSubdirectory = "E5Small"
    private static let modelResourceName = "model_quantized"

    private var tokenizer: Tokenizer?
    private var session: ORTSession?
    private var env: ORTEnv?
    private var loadError: Error?

    /// 실제로 임베딩을 계산할 수 있는 상태로 토크나이저·세션을 준비한다. 여러 번 불러도 안전하다.
    func prepare() async throws {
        if session != nil { return }
        if let loadError { throw loadError }

        do {
            guard let modelFolder = Bundle.main.url(
                forResource: Self.resourceSubdirectory,
                withExtension: nil
            ) else {
                throw OnnxEmbeddingError.modelUnavailable("\(Self.resourceSubdirectory) 리소스 폴더를 번들에서 찾지 못했다")
            }
            guard let modelPath = Bundle.main.path(
                forResource: Self.modelResourceName,
                ofType: "onnx",
                inDirectory: Self.resourceSubdirectory
            ) else {
                throw OnnxEmbeddingError.modelUnavailable("\(Self.modelResourceName).onnx를 번들에서 찾지 못했다")
            }

            let loadedTokenizer = try await AutoTokenizer.from(modelFolder: modelFolder)
            let ortEnv = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            let ortSession = try ORTSession(env: ortEnv, modelPath: modelPath, sessionOptions: options)

            tokenizer = loadedTokenizer
            env = ortEnv
            session = ortSession
        } catch {
            loadError = error
            throw error
        }
    }

    /// 텍스트 하나를 벡터 하나로. `kind`로 검색어("query: ")/색인 대상("passage: ") 접두어를 고른다.
    func embed(_ text: String, as kind: OnnxEmbeddingInputKind) async throws -> [Double] {
        try await prepare()
        guard let tokenizer, let session else {
            throw OnnxEmbeddingError.modelUnavailable("모델이 로드되지 않았다")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnnxEmbeddingError.emptyText }

        let prefix = kind == .query ? "query: " : "passage: "
        let inputIds = tokenizer(prefix + trimmed).map { Int64($0) }
        let sequenceLength = inputIds.count
        let attentionMask = [Int64](repeating: 1, count: sequenceLength)
        let tokenTypeIds = [Int64](repeating: 0, count: sequenceLength)

        let shape: [NSNumber] = [1, NSNumber(value: sequenceLength)]
        let outputs = try session.run(
            withInputs: [
                "input_ids": try Self.int64Tensor(inputIds, shape: shape),
                "attention_mask": try Self.int64Tensor(attentionMask, shape: shape),
                "token_type_ids": try Self.int64Tensor(tokenTypeIds, shape: shape),
            ],
            outputNames: ["last_hidden_state"],
            runOptions: nil
        )
        guard let hiddenStateValue = outputs["last_hidden_state"] else {
            throw OnnxEmbeddingError.modelUnavailable("출력에 last_hidden_state가 없다")
        }
        let hiddenState = try Self.floatArray(from: hiddenStateValue)

        let hiddenSize = hiddenState.count / sequenceLength
        var pooled = [Double](repeating: 0, count: hiddenSize)
        for position in 0..<sequenceLength {
            let base = position * hiddenSize
            for dim in 0..<hiddenSize {
                pooled[dim] += Double(hiddenState[base + dim])
            }
        }
        for dim in 0..<hiddenSize {
            pooled[dim] /= Double(sequenceLength)
        }

        let norm = sqrt(pooled.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return pooled }
        return pooled.map { $0 / norm }
    }

    private static func int64Tensor(_ values: [Int64], shape: [NSNumber]) throws -> ORTValue {
        var mutableValues = values
        let data = NSMutableData(
            bytes: &mutableValues,
            length: mutableValues.count * MemoryLayout<Int64>.stride
        )
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape)
    }

    private static func floatArray(from value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}
