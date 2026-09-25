import XCTest
@testable import CapPick

/// substring-only(현재 서버 경로와 유사한 어휘 일치) / embedding-only(OnnxEmbeddingService만) /
/// hybrid-RRF(둘을 Reciprocal Rank Fusion으로 결합) 세 가지 검색 전략을 같은 코퍼스·질의로
/// 비교하는 평가 하네스다. **아직 SearchService에 어떤 것도 연결하지 않는다** — Phase 3 진행 여부를
/// 실제 데이터로 판단하기 위한 측정 전용 코드다.
///
/// **코퍼스 재작성 (2026-09-25, 사용자 요청).** 이전 버전(159문서)은 문서 수를 늘리는 데는
/// 성공했지만, 문서 92%(147/159)에 "캡처"라는 공통 문체가 반복돼 있었고 — 통제 실험으로 확인한 결과
/// (CLAUDE.md "semantic Top-1 실패 원인 분석" 절 참고) 이게 측정을 오염시켰을 가능성이 있었다.
/// 이번엔 **실제 서버 `content_analysis`가 만드는 형태를 그대로 재현**한다 — `ocrText`(화면에서
/// 그대로 읽히는 글자, 메뉴명·가격·버튼 텍스트 같은 UI 조각이 섞인 비문 형태),
/// `observedEvidence`(관찰 가능한 사실만 짧게 나열, `GeminiContentAnalysisClient.PROMPT` 규칙과
/// 동일), `searchText`(나중에 자연어로 찾을 수 있도록 만든 한 줄 요약 — **실제로 임베딩되는 건
/// 이 필드뿐이다**, `GeminiContentAnalysisClient.analyze()`의 `embed(searchText)` 호출과 동일하게
/// 이 하네스도 `embeddingText`(= searchText)만 임베딩한다). "OOO 캡처"처럼 모든 문서에 반복되는
/// 인위적 공통 표현은 넣지 않는다.
///
/// **질의를 세 유형으로 명확히 나눈다** — 사용자가 실제로 입력할 법한 표현 스타일 자체가 구분
/// 대상이다: `.shortKeyword`(예: "사주"), `.naturalLanguage`(예: "전에 봤던 사주 결과" — 표현은
/// 달라도 의미가 같음), `.exactIdentifier`(에러 코드·과목 코드·날짜·모델명처럼 정확한 문자열이
/// 중요함). 같은 정답 문서에 대해 `.shortKeyword`/`.naturalLanguage`를 짝으로 만들어서(`topic`
/// 값 공유) 질의 표현 방식에 따른 성능 차이를 직접 비교할 수 있게 한다.
///
/// **hybrid-RRF 파라미터는 이전 재설계 그대로 고정한다(사용자 지시, 2026-09-25) — k=5,
/// matchRatio 가중 로직 모두 이번 재평가 결과에 맞춰 추가 튜닝하지 않는다.** 왜 이 값인지는
/// `rrfRanking`/`rrfConstant` 문서 주석 참고.
final class SearchStrategyEvaluationTests: XCTestCase {
    /// 서버 `ContentAnalysisResultDTO`(ocrText/observedEvidence/searchText)를 그대로 반영한다.
    private struct Document {
        let id: String
        /// 화면에서 그대로 읽히는 글자 — UI 라벨·가격·버튼 문구가 섞인 비문 형태(실제 OCR처럼).
        let ocrText: String
        /// 관찰 가능한 사실만 짧게 나열(추측 금지) — 서버 프롬프트 규칙과 동일.
        let observedEvidence: [String]
        /// 자연어 검색을 위해 만든 한 줄 요약 — 세 필드 중 유일하게 매끄러운 문장.
        let searchText: String

        /// 실제로 임베딩되는 텍스트. 서버가 `embed(searchText)`만 호출하는 것과 동일하게
        /// (`GeminiContentAnalysisClient.analyze()`), 이 하네스도 searchText만 임베딩한다.
        var embeddingText: String { searchText }
        /// substring이 뒤지는 텍스트. 로컬 클라이언트가 실제로 어디까지 인덱싱할지는 아직
        /// 정해진 바 없어(로컬 검색 코드 미착수), 캡처 하나가 가진 텍스트를 전부(OCR+관찰
        /// 근거+검색 요약) 인덱싱한다는 가장 관대한 가정으로 substring-only의 상한을 잡는다.
        var indexedText: String { ([ocrText] + observedEvidence + [searchText]).joined(separator: " ") }
    }

    private struct EvalCase {
        let label: String
        let query: String
        let expectedDocumentID: String
        let kind: Kind
        /// 같은 topic 값을 공유하는 .shortKeyword/.naturalLanguage 쌍을 나중에 묶어서 비교한다.
        let topic: String?

        enum Kind: String, CaseIterable {
            case shortKeyword
            case naturalLanguage
            case exactIdentifier
        }
    }

    // MARK: - 코퍼스: 주제 문서 10개 (키워드/자연어 질의 짝을 만들 수 있는 대상)

    private static let topicDocuments: [Document] = [
        Document(
            id: "saju",
            ocrText: "무료사주 만세력\n생년월일시\n1997년 3월 14일 오전 7시\n사주팔자 보기\n오행 분석 결과\n목(木) 2 화(火) 1 토(土) 3 금(金) 1 수(水) 1\n다시 보기",
            observedEvidence: ["사주 계산 앱 화면이다", "생년월일과 태어난 시각이 입력되어 있다", "오행별 개수가 표 형태로 표시된다"],
            searchText: "생년월일 기반 사주팔자 오행 분석 결과를 확인한 화면"
        ),
        Document(
            id: "interview",
            ocrText: "카카오 기술 면접 후기 모음\nQ. 해시테이블과 트리의 차이는?\nQ. TCP와 UDP 차이 설명\nQ. 프로세스와 스레드 차이\n북마크 128 댓글 34",
            observedEvidence: ["기술 면접 후기 게시글 화면이다", "면접 질문 목록이 나열되어 있다", "자료구조·네트워크·운영체제 관련 질문이 포함된다"],
            searchText: "카카오 기술 면접에서 나온 질문들을 정리한 커뮤니티 게시글"
        ),
        Document(
            id: "pasta",
            ocrText: "망원동 파스타 맛집 후기\n크림파스타 18000원\n웨이팅 40분\n재방문 의사 있음\n★★★★★",
            observedEvidence: ["레스토랑 리뷰 게시글이다", "메뉴 이름과 가격이 표시된다", "웨이팅 시간이 언급된다"],
            searchText: "망원동 파스타 맛집 방문 후기, 웨이팅과 재방문 의사 포함"
        ),
        Document(
            id: "os",
            ocrText: "운영체제 중간고사 범위\n1장~4장 (프로세스, 스레드, 스케줄링, 동기화)\n계산 문제 출제 예정\n족보 참고할 것",
            observedEvidence: ["시험 범위 공지 화면이다", "1장부터 4장까지 범위가 명시된다", "계산 문제가 출제된다는 안내가 있다"],
            searchText: "운영체제 중간고사 시험 범위와 출제 유형 공지"
        ),
        Document(
            id: "dress",
            ocrText: "여름 신상 원피스\n29,000원 → 19,900원\n사이즈 S/M/L\n리뷰 1,204\n장바구니 담기",
            observedEvidence: ["쇼핑몰 상품 상세 화면이다", "할인 전후 가격이 표시된다", "사이즈 옵션이 나열된다"],
            searchText: "여름 원피스 할인 상품 페이지, 사이즈와 리뷰 포함"
        ),
        Document(
            id: "gym",
            ocrText: "하체 운동 루틴\n스쿼트 60kg x 10 x 4세트\n레그프레스 100kg x 12 x 3세트\n다음 운동일: 목요일",
            observedEvidence: ["운동 기록 앱 화면이다", "종목별 무게와 횟수, 세트 수가 기록되어 있다", "다음 운동 예정일이 표시된다"],
            searchText: "헬스장 하체 운동 기록, 스쿼트와 레그프레스 무게 포함"
        ),
        Document(
            id: "realEstate",
            ocrText: "역삼동 오피스텔 전세\n보증금 2억 3천\n21평 / 5층\n즉시 입주 가능\n중개사 문의",
            observedEvidence: ["부동산 매물 상세 화면이다", "보증금 금액이 명시된다", "평수와 층수가 표시된다"],
            searchText: "역삼동 오피스텔 전세 매물 정보, 보증금과 평수 포함"
        ),
        Document(
            id: "petWalk",
            ocrText: "강아지 산책 코스 지도\n한바퀴 1.8km\n소요시간 32분\n오늘 걸음수 4,120보",
            observedEvidence: ["산책 기록 앱의 지도 화면이다", "이동 거리와 소요 시간이 표시된다", "걸음 수가 함께 기록된다"],
            searchText: "강아지와 다녀온 산책 코스와 거리 기록"
        ),
        Document(
            id: "drama",
            ocrText: "지금 뜨는 콘텐츠\n무빙 시즌1\n시청 완료 92%\n다음 에피소드 재생\n내가 찜한 콘텐츠 추가됨",
            observedEvidence: ["스트리밍 앱 홈 화면이다", "특정 드라마의 시청 진행률이 표시된다", "찜 목록에 추가됐다는 안내가 있다"],
            searchText: "넷플릭스에서 보던 드라마 시청 진행 상황 화면"
        ),
        Document(
            id: "savings",
            ocrText: "정기적금 가입 완료\n월 30만원 x 12개월\n금리 연 3.8%\n만기일 2027-09-25",
            observedEvidence: ["은행 앱의 적금 가입 완료 화면이다", "월 납입액과 기간이 표시된다", "금리와 만기일이 명시된다"],
            searchText: "정기적금 신규 가입 완료 내역, 금리와 만기일 포함"
        ),
    ]

    // MARK: - 코퍼스: exact identifier 문서 30개 (카테고리당 6개)

    private static let identifierDocuments: [Document] = [
        // 에러 코드
        Document(id: "err500", ocrText: "500\nInternal Server Error\n서버에 일시적인 문제가 발생했습니다\n잠시 후 다시 시도해주세요\n[다시 시도]",
                 observedEvidence: ["오류 화면이다", "오류 코드 500이 크게 표시된다", "재시도 버튼이 있다"],
                 searchText: "앱 사용 중 500 서버 내부 오류가 발생한 화면"),
        Document(id: "err501", ocrText: "501\nNot Implemented\n요청한 기능은 아직 지원되지 않습니다\n고객센터 문의",
                 observedEvidence: ["오류 화면이다", "오류 코드 501이 표시된다", "고객센터 문의 안내가 있다"],
                 searchText: "지원하지 않는 기능 요청으로 501 오류가 뜬 화면"),
        Document(id: "err503", ocrText: "503\nService Unavailable\n현재 접속자가 많아 서비스 이용이 어렵습니다\n잠시 후 다시 접속해주세요",
                 observedEvidence: ["오류 화면이다", "오류 코드 503이 표시된다", "접속자 폭주 안내 문구가 있다"],
                 searchText: "접속자 폭주로 503 서비스 이용 불가 오류가 뜬 화면"),
        Document(id: "err401", ocrText: "401\nUnauthorized\n로그인이 만료되었습니다\n다시 로그인해주세요\n[로그인 화면으로]",
                 observedEvidence: ["오류 화면이다", "오류 코드 401이 표시된다", "로그인 만료 안내가 있다"],
                 searchText: "로그인 세션 만료로 401 인증 오류가 뜬 화면"),
        Document(id: "err404", ocrText: "404\nPage Not Found\n요청하신 페이지를 찾을 수 없습니다\n홈으로 돌아가기",
                 observedEvidence: ["오류 화면이다", "오류 코드 404가 표시된다", "홈으로 돌아가는 버튼이 있다"],
                 searchText: "존재하지 않는 페이지 접근으로 404 오류가 뜬 화면"),
        Document(id: "err429", ocrText: "429\nToo Many Requests\n요청이 너무 많습니다\n1분 후 다시 시도해주세요",
                 observedEvidence: ["오류 화면이다", "오류 코드 429가 표시된다", "요청 제한 안내 문구가 있다"],
                 searchText: "짧은 시간 요청 과다로 429 오류가 뜬 화면"),

        // 과목 코드
        Document(id: "cs101", ocrText: "CS101 자료구조\n중간고사 범위: 1~6장\n시험일: 10월 15일\nLMS 공지사항",
                 observedEvidence: ["학교 LMS 공지사항 화면이다", "과목명과 과목코드가 표시된다", "시험 범위와 날짜가 안내된다"],
                 searchText: "CS101 자료구조 중간고사 범위와 시험일 공지"),
        Document(id: "cs201", ocrText: "CS201 알고리즘\n과제 3 제출 마감: 11월 3일 23:59\n지각 제출 시 감점\n제출하기",
                 observedEvidence: ["과제 제출 화면이다", "과목코드와 과제 번호가 표시된다", "마감 시각이 명시된다"],
                 searchText: "CS201 알고리즘 과제 제출 마감 안내"),
        Document(id: "math101", ocrText: "MATH101 미적분학\n기말고사 성적 발표\n내 점수: 87/100\n평균 74.2",
                 observedEvidence: ["성적 확인 화면이다", "과목코드와 점수가 표시된다", "전체 평균이 함께 표시된다"],
                 searchText: "MATH101 미적분학 기말고사 성적 확인 화면"),
        Document(id: "eng201", ocrText: "ENG201 영작문\nEssay 2 피드백 도착\n담당교수: Kim\n첨삭 내용 확인하기",
                 observedEvidence: ["과제 피드백 알림 화면이다", "과목코드가 표시된다", "담당 교수명이 표시된다"],
                 searchText: "ENG201 영작문 과제 첨삭 피드백 도착 알림"),
        Document(id: "stat201", ocrText: "STAT201 통계학\n분반 변경 신청 기간\n9월 20일~9월 24일\n선착순 마감",
                 observedEvidence: ["수강신청 관련 공지 화면이다", "과목코드와 신청 기간이 표시된다"],
                 searchText: "STAT201 통계학 분반 변경 신청 기간 공지"),
        Document(id: "phys101", ocrText: "PHYS101 일반물리학\n실험 조 배정표\n3조: 화요일 2교시\n실험실 401호",
                 observedEvidence: ["실험 조 배정 공지 화면이다", "과목코드와 조·시간이 표시된다", "실험실 호수가 표시된다"],
                 searchText: "PHYS101 일반물리학 실험 조 배정과 시간 공지"),

        // 장소명
        Document(id: "sokcho", ocrText: "속초 여행 2박3일 일정표\n1일차: 속초해수욕장, 중앙시장\n2일차: 설악산 케이블카\n숙소: 속초 오션뷰 게스트하우스",
                 observedEvidence: ["여행 일정표 메모 화면이다", "지역명과 방문 장소가 나열된다", "숙소 이름이 포함된다"],
                 searchText: "속초 2박3일 여행 일정과 방문 장소 목록"),
        Document(id: "yeouido", ocrText: "여의도 불꽃축제 명당 자리\n한강공원 잔디광장\n오후 4시부터 자리 선점 필요\n돗자리 필수",
                 observedEvidence: ["행사 관련 정보 화면이다", "지역명과 장소가 명시된다", "준비물이 안내된다"],
                 searchText: "여의도 불꽃축제 명당 자리와 준비물 정보"),
        Document(id: "jamsil", ocrText: "잠실 야구장 직관 후기\n3루 응원석에서 관람\n경기 끝나고 잠실새내역까지 도보 15분",
                 observedEvidence: ["야구 직관 후기 게시글이다", "지역명과 좌석 위치가 언급된다", "이동 소요 시간이 포함된다"],
                 searchText: "잠실 야구장 직관 후기와 자리 위치"),
        Document(id: "sinchon", ocrText: "신촌 회식 장소 후보\n1. 고깃집 - 룸 예약 가능\n2. 이자카야 - 20명 수용\n예산 1인 3만원",
                 observedEvidence: ["회식 장소 후보 메모다", "지역명과 후보 식당이 나열된다", "1인 예산이 표시된다"],
                 searchText: "신촌 회식 장소 후보와 예산 정리"),
        Document(id: "pangyo", ocrText: "판교 사무실 출근 경로\n신분당선 판교역 2번 출구\n도보 8분\n셔틀버스 시간표 확인",
                 observedEvidence: ["출퇴근 경로 메모 화면이다", "지역명과 지하철역·출구가 표시된다", "셔틀버스 안내가 포함된다"],
                 searchText: "판교 사무실 출근 경로와 지하철역 정보"),
        Document(id: "hongdae", ocrText: "홍대 프리마켓 부스 위치\nA구역 12번 부스\n토요일 12시~18시 운영",
                 observedEvidence: ["행사 부스 안내 화면이다", "지역명과 부스 번호가 표시된다", "운영 시간이 명시된다"],
                 searchText: "홍대 프리마켓 부스 위치와 운영 시간"),

        // 상품 모델명
        Document(id: "iphone15", ocrText: "iPhone 15 Pro 자급제\n256GB 블루티타늄\n1,550,000원\n오늘출발",
                 observedEvidence: ["쇼핑몰 상품 상세 화면이다", "모델명과 용량, 색상이 표시된다", "가격과 배송 정보가 포함된다"],
                 searchText: "아이폰 15 프로 자급제 모델 가격과 배송 정보"),
        Document(id: "iphone14", ocrText: "iPhone 14 Pro 중고 S급\n256GB 딥퍼플\n980,000원\n직거래 가능",
                 observedEvidence: ["중고거래 상품 화면이다", "모델명과 상태 등급이 표시된다", "가격이 표시된다"],
                 searchText: "아이폰 14 프로 중고 판매 가격과 상태"),
        Document(id: "galaxyS24", ocrText: "갤럭시 S24 울트라\n사전예약 혜택\n갤럭시버즈 증정\n예약금 10,000원",
                 observedEvidence: ["사전예약 안내 화면이다", "모델명과 증정품이 표시된다", "예약금이 명시된다"],
                 searchText: "갤럭시 S24 울트라 사전예약 혜택과 증정품 안내"),
        Document(id: "macbookPro14", ocrText: "MacBook Pro 14 M4\n스페이스블랙 512GB\n2,690,000원\n애플케어+ 별도",
                 observedEvidence: ["쇼핑몰 상품 상세 화면이다", "모델명과 칩셋, 용량이 표시된다", "가격이 표시된다"],
                 searchText: "맥북 프로 14인치 M4 모델 가격 정보"),
        Document(id: "airpodsPro2", ocrText: "AirPods Pro 2세대\nUSB-C\n289,000원\n리뷰 3,402\n무료배송",
                 observedEvidence: ["쇼핑몰 상품 상세 화면이다", "모델명과 세대, 커넥터 타입이 표시된다", "리뷰 수가 표시된다"],
                 searchText: "에어팟 프로 2세대 USB-C 모델 가격과 리뷰"),
        Document(id: "galaxyWatch6", ocrText: "Galaxy Watch6 44mm\n실버 색상\n재고 2개 남음\n228,000원",
                 observedEvidence: ["쇼핑몰 상품 상세 화면이다", "모델명과 사이즈, 색상이 표시된다", "재고 수량이 표시된다"],
                 searchText: "갤럭시워치6 44mm 실버 재고와 가격 정보"),

        // 날짜
        Document(id: "mtg0920", ocrText: "9/20 (토) 팀 회고\n이번 스프린트 잘된 점 / 아쉬운 점\n다음 스프린트 목표 논의\n장소: 회의실 A",
                 observedEvidence: ["팀 회고 일정 화면이다", "날짜가 9월 20일로 표시된다", "회의 장소가 명시된다"],
                 searchText: "9월 20일 팀 회고 미팅 일정과 장소"),
        Document(id: "mtg0922", ocrText: "9/22 (월) 디자인 리뷰\n신규 온보딩 플로우 시안 공유\n참석자: 디자인팀 전원\n오후 2시",
                 observedEvidence: ["디자인 리뷰 일정 화면이다", "날짜가 9월 22일로 표시된다", "참석 대상과 시간이 명시된다"],
                 searchText: "9월 22일 디자인 리뷰 미팅 일정과 참석자"),
        Document(id: "mtg0925", ocrText: "9/25 (목) 스프린트 계획\n다음 2주 백로그 정리\nPO 참석 필수\n오전 10시 시작",
                 observedEvidence: ["스프린트 계획 회의 일정이다", "날짜가 9월 25일로 표시된다", "시작 시각이 명시된다"],
                 searchText: "9월 25일 스프린트 계획 회의 일정"),
        Document(id: "mtg0927", ocrText: "9/27 (토) 워크숍\n외부 강사 초청 세미나\n장소: 강남 컨퍼런스룸\n점심 제공",
                 observedEvidence: ["워크숍 일정 화면이다", "날짜가 9월 27일로 표시된다", "장소와 제공 사항이 명시된다"],
                 searchText: "9월 27일 워크숍 세미나 일정과 장소"),
        Document(id: "mtg0929", ocrText: "9/29 (월) 분기 실적 발표\n임원진 대상 보고\n자료 마감: 9/28 자정\n대회의실",
                 observedEvidence: ["실적 발표 일정 화면이다", "날짜가 9월 29일로 표시된다", "자료 마감일이 함께 표시된다"],
                 searchText: "9월 29일 분기 실적 발표 일정과 자료 마감"),
        Document(id: "mtg1003", ocrText: "10/3 (금) 신입 온보딩\n오리엔테이션 9시~12시\n장소: 교육장 2\n노트북 지참",
                 observedEvidence: ["온보딩 일정 화면이다", "날짜가 10월 3일로 표시된다", "준비물이 안내된다"],
                 searchText: "10월 3일 신입 온보딩 오리엔테이션 일정"),
    ]

    // MARK: - 코퍼스: 무관한 필러 문서 18개 (공통 문체 없이 서로 다른 도메인)

    private static let fillerDocuments: [Document] = [
        Document(id: "filler_delivery", ocrText: "CJ대한통운\n배송중\n상품: 무선청소기\n도착예정 09/26 오후",
                 observedEvidence: ["택배 배송 조회 화면이다", "택배사와 배송 상태가 표시된다", "도착 예정일이 안내된다"],
                 searchText: "무선청소기 택배 배송 조회, 도착 예정일 확인"),
        Document(id: "filler_cafe", ocrText: "아이스 아메리카노 Tall\n샷 추가\n주문번호 47\n제조중",
                 observedEvidence: ["카페 앱 주문 상태 화면이다", "음료 옵션과 주문번호가 표시된다"],
                 searchText: "카페 아메리카노 주문 진행 상태 확인"),
        Document(id: "filler_bus", ocrText: "402번\n다음 정류장 도착\n2분 후\n혼잡도: 보통",
                 observedEvidence: ["버스 도착 정보 앱 화면이다", "노선 번호와 도착 시간이 표시된다"],
                 searchText: "402번 버스 도착 시간과 혼잡도 확인"),
        Document(id: "filler_youtube", ocrText: "구독 채널 알림\n새 영상 업로드\n조회수 12만\n댓글 890",
                 observedEvidence: ["유튜브 알림 화면이다", "구독 채널의 새 영상 알림이 표시된다"],
                 searchText: "구독 채널 새 영상 업로드 알림"),
        Document(id: "filler_hospital", ocrText: "정형외과 예약 확인\n10/2 (수) 오후 3시\n담당의: 박OO 원장\n접수번호 15",
                 observedEvidence: ["병원 예약 확인 화면이다", "진료과와 예약 일시가 표시된다"],
                 searchText: "정형외과 진료 예약 확인, 날짜와 담당의"),
        Document(id: "filler_electricity", ocrText: "이번달 전기요금\n42,300원\n전월 대비 +8%\n납부기한 9/30",
                 observedEvidence: ["공과금 고지서 화면이다", "청구 금액과 전월 대비 증감이 표시된다"],
                 searchText: "이번달 전기요금 고지서, 전월 대비 증가"),
        Document(id: "filler_kakao", ocrText: "엄마: 저녁 뭐 먹을거니\n나: 아직 모르겠어요\n엄마: 김치찌개 해뒀다\n나: 넵 감사합니다",
                 observedEvidence: ["메신저 대화 화면이다", "가족과의 저녁 메뉴 관련 대화다"],
                 searchText: "엄마와 저녁 메뉴 관련 나눈 카톡 대화"),
        Document(id: "filler_insta", ocrText: "친구 결혼식 피드\n좋아요 342\n댓글 58개\n#결혼식 #축하",
                 observedEvidence: ["SNS 피드 게시물이다", "결혼식 관련 해시태그가 포함된다", "좋아요·댓글 수가 표시된다"],
                 searchText: "친구 결혼식 인스타그램 게시물"),
        Document(id: "filler_stock", ocrText: "삼성전자\n71,200원 ▲1.2%\n보유수량 15주\n평가손익 +32,000원",
                 observedEvidence: ["주식 앱 종목 화면이다", "현재가와 등락률이 표시된다", "보유 수량과 평가손익이 표시된다"],
                 searchText: "삼성전자 주식 현재가와 평가손익 확인"),
        Document(id: "filler_flight", ocrText: "인천→제주\n9/30 (화) 09:20 출발\n예약번호 KE1234ABC\n탑승수속 안내",
                 observedEvidence: ["항공권 예약 확인 화면이다", "출발지·도착지와 시간이 표시된다", "예약번호가 표시된다"],
                 searchText: "인천발 제주행 항공권 예약 확인"),
        Document(id: "filler_gameitem", ocrText: "전설 등급 무기 획득\n공격력 +320\n인벤토리 47/60\n강화하기",
                 observedEvidence: ["모바일 게임 아이템 획득 화면이다", "등급과 능력치가 표시된다"],
                 searchText: "게임에서 전설 등급 무기 획득한 화면"),
        Document(id: "filler_library", ocrText: "대출 도서 목록\n『프로젝트 헤일메리』 반납일 10/5\n연장 가능\n연장하기",
                 observedEvidence: ["도서관 앱 대출 현황 화면이다", "도서명과 반납일이 표시된다"],
                 searchText: "도서관 대출 도서 반납일과 연장 안내"),
        Document(id: "filler_weather", ocrText: "서울\n맑음 23°C\n미세먼지 나쁨\n우산 필요 없음",
                 observedEvidence: ["날씨 앱 화면이다", "기온과 미세먼지 수준이 표시된다"],
                 searchText: "서울 날씨와 미세먼지 수준 확인"),
        Document(id: "filler_movie", ocrText: "CGV 강남\n인터스텔라 리마스터링\n10/1 (수) 19:40\nG열 12,13번",
                 observedEvidence: ["영화 예매 확인 화면이다", "상영관과 시간, 좌석이 표시된다"],
                 searchText: "CGV 강남 영화 예매 확인, 상영 시간과 좌석"),
        Document(id: "filler_recipe", ocrText: "된장찌개 레시피\n재료: 두부, 애호박, 된장 2큰술\n조리시간 20분\n난이도 하",
                 observedEvidence: ["레시피 화면이다", "재료 목록과 조리 시간이 표시된다"],
                 searchText: "된장찌개 만드는 법과 재료 목록"),
        Document(id: "filler_parking", ocrText: "지하 2층 B-14\n입차 14:32\n요금 정산 필요\n정산하기",
                 observedEvidence: ["주차 위치·요금 화면이다", "입차 시간과 구역이 표시된다"],
                 searchText: "주차 위치와 입차 시간, 정산 안내"),
        Document(id: "filler_dentist", ocrText: "스케일링 예약\n10/8 (수) 오전 11시\n비급여 항목 안내\n예약 변경/취소",
                 observedEvidence: ["치과 예약 확인 화면이다", "진료 항목과 예약 일시가 표시된다"],
                 searchText: "치과 스케일링 예약 확인과 일시"),
        Document(id: "filler_webtoon", ocrText: "화신 128화\n좋아요 4.2만\n다음화 예고\n별점 9.8",
                 observedEvidence: ["웹툰 뷰어 화면이다", "회차와 별점, 좋아요 수가 표시된다"],
                 searchText: "웹툰 화신 128화 감상 화면"),
    ]

    private static var corpus: [Document] { topicDocuments + identifierDocuments + fillerDocuments }

    // MARK: - 질의: shortKeyword/naturalLanguage 짝 10쌍 + exactIdentifier 15개

    private static let evalCases: [EvalCase] = [
        // 짝 1 — 사주
        EvalCase(label: "사주(짧은 키워드)", query: "사주", expectedDocumentID: "saju", kind: .shortKeyword, topic: "saju"),
        EvalCase(label: "사주(자연어)", query: "전에 봤던 사주 결과", expectedDocumentID: "saju", kind: .naturalLanguage, topic: "saju"),
        // 짝 2 — 면접
        EvalCase(label: "면접(짧은 키워드)", query: "면접", expectedDocumentID: "interview", kind: .shortKeyword, topic: "interview"),
        EvalCase(label: "면접(자연어)", query: "개발자 인터뷰 준비하면서 저장해둔 글", expectedDocumentID: "interview", kind: .naturalLanguage, topic: "interview"),
        // 짝 3 — 파스타
        EvalCase(label: "파스타(짧은 키워드)", query: "파스타", expectedDocumentID: "pasta", kind: .shortKeyword, topic: "pasta"),
        EvalCase(label: "파스타(자연어)", query: "데이트할 때 갈 식당 찾아본 거", expectedDocumentID: "pasta", kind: .naturalLanguage, topic: "pasta"),
        // 짝 4 — 운영체제
        EvalCase(label: "운영체제(짧은 키워드)", query: "운영체제", expectedDocumentID: "os", kind: .shortKeyword, topic: "os"),
        EvalCase(label: "운영체제(자연어)", query: "OS 시험 공부하려고 저장한 공지", expectedDocumentID: "os", kind: .naturalLanguage, topic: "os"),
        // 짝 5 — 원피스
        EvalCase(label: "원피스(짧은 키워드)", query: "원피스", expectedDocumentID: "dress", kind: .shortKeyword, topic: "dress"),
        EvalCase(label: "원피스(자연어)", query: "옷 사려고 봐두었던 쇼핑몰 페이지", expectedDocumentID: "dress", kind: .naturalLanguage, topic: "dress"),
        // 짝 6 — 헬스
        EvalCase(label: "헬스(짧은 키워드)", query: "헬스", expectedDocumentID: "gym", kind: .shortKeyword, topic: "gym"),
        EvalCase(label: "헬스(자연어)", query: "운동 기록해둔 거 몇 킬로였는지 보려고", expectedDocumentID: "gym", kind: .naturalLanguage, topic: "gym"),
        // 짝 7 — 전세
        EvalCase(label: "전세(짧은 키워드)", query: "전세", expectedDocumentID: "realEstate", kind: .shortKeyword, topic: "realEstate"),
        EvalCase(label: "전세(자연어)", query: "이사 갈까 하고 봐뒀던 집 매물", expectedDocumentID: "realEstate", kind: .naturalLanguage, topic: "realEstate"),
        // 짝 8 — 산책
        EvalCase(label: "산책(짧은 키워드)", query: "산책", expectedDocumentID: "petWalk", kind: .shortKeyword, topic: "petWalk"),
        EvalCase(label: "산책(자연어)", query: "강아지랑 걸었던 동네 코스 다시 보려고", expectedDocumentID: "petWalk", kind: .naturalLanguage, topic: "petWalk"),
        // 짝 9 — 드라마
        EvalCase(label: "드라마(짧은 키워드)", query: "드라마", expectedDocumentID: "drama", kind: .shortKeyword, topic: "drama"),
        EvalCase(label: "드라마(자연어)", query: "보다 말았던 거 이어보려고 저장한 화면", expectedDocumentID: "drama", kind: .naturalLanguage, topic: "drama"),
        // 짝 10 — 적금
        EvalCase(label: "적금(짧은 키워드)", query: "적금", expectedDocumentID: "savings", kind: .shortKeyword, topic: "savings"),
        EvalCase(label: "적금(자연어)", query: "돈 모으려고 가입했던 상품 만기일 확인하려고", expectedDocumentID: "savings", kind: .naturalLanguage, topic: "savings"),

        // exact identifier — 카테고리당 3개
        EvalCase(label: "에러 코드 - HTTP 503", query: "HTTP 503", expectedDocumentID: "err503", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "에러 코드 - 401 오류", query: "401 오류", expectedDocumentID: "err401", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "에러 코드 - 429", query: "429", expectedDocumentID: "err429", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "과목 코드 - CS101", query: "CS101 시험범위", expectedDocumentID: "cs101", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "과목 코드 - STAT201", query: "STAT201 분반변경", expectedDocumentID: "stat201", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "과목 코드 - MATH101", query: "MATH101 성적", expectedDocumentID: "math101", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "장소명 - 속초", query: "속초 여행", expectedDocumentID: "sokcho", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "장소명 - 여의도", query: "여의도 불꽃축제", expectedDocumentID: "yeouido", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "장소명 - 판교", query: "판교 출근길", expectedDocumentID: "pangyo", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "상품 모델명 - 아이폰 15 프로", query: "아이폰 15 프로 가격", expectedDocumentID: "iphone15", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "상품 모델명 - 갤럭시 S24", query: "갤럭시 S24 사전예약", expectedDocumentID: "galaxyS24", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "상품 모델명 - 맥북 프로 14인치", query: "맥북 프로 14인치", expectedDocumentID: "macbookPro14", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "날짜 - 9월 25일", query: "9월 25일 회의", expectedDocumentID: "mtg0925", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "날짜 - 9월 20일", query: "9월 20일 회고", expectedDocumentID: "mtg0920", kind: .exactIdentifier, topic: nil),
        EvalCase(label: "날짜 - 9월 29일", query: "9월 29일 실적발표", expectedDocumentID: "mtg0929", kind: .exactIdentifier, topic: nil),
    ]

    /// RRF 문헌의 표준값 k=60은 웹 규모(수천~수만 개 깊은 순위)에서 튜닝된 값이다 — k가 클수록
    /// "1위와 4위의 차이"를 작게 뭉갠다. 작은 코퍼스에서는 순위 차이 자체가 훨씬 더 큰 신호라
    /// k=5로 낮췄다(자세한 경위는 git 이력·CLAUDE.md "RRF 재설계" 절 참고). **이번 코퍼스
    /// 재작성 평가에서는 이 값과 matchRatio 가중 로직을 결과에 맞춰 추가로 튜닝하지 않는다(사용자
    /// 지시, 2026-09-25)** — 이번 목적은 파라미터 최적화가 아니라 "더 현실적인 코퍼스·질의
    /// 구성에서도 지금까지의 결론이 유지되는지" 확인하는 것이다.
    private static let rrfConstant = 5.0

    func testCompareSearchStrategies() async throws {
        let embeddingService = OnnxEmbeddingService()

        var docEmbeddings: [String: [Double]] = [:]
        for doc in Self.corpus {
            docEmbeddings[doc.id] = try await embeddingService.embed(doc.embeddingText, as: .passage)
        }

        // rank == nil이면 그 전략의 결과 목록에 정답 문서가 아예 없었다는 뜻(특히 substring은
        // 어휘가 하나도 안 겹치면 그 문서를 후보에서 통째로 뺀다).
        var ranks: [String: [Int?]] = ["substring": [], "embedding": [], "hybridRRF": []]
        var ranksByKind: [EvalCase.Kind: [String: [Int?]]] = [:]
        var failureDetails: [String] = []

        for evalCase in Self.evalCases {
            let queryEmbedding = try await embeddingService.embed(evalCase.query, as: .query)

            let substringRanking = Self.substringRanking(query: evalCase.query, corpus: Self.corpus)
            let embeddingRanking = Self.embeddingRanking(queryEmbedding: queryEmbedding, docEmbeddings: docEmbeddings, corpus: Self.corpus)
            let hybridRanking = Self.rrfRanking(substringRanking, embeddingRanking, corpus: Self.corpus, k: Self.rrfConstant)

            let substringIDs = substringRanking.map(\.document.id)
            let embeddingIDs = embeddingRanking.map(\.document.id)
            let hybridIDs = hybridRanking.map(\.id)

            var caseRanks: [String: Int?] = [:]
            for (strategy, ids) in [("substring", substringIDs), ("embedding", embeddingIDs), ("hybridRRF", hybridIDs)] {
                let rank = ids.firstIndex(of: evalCase.expectedDocumentID).map { $0 + 1 }
                caseRanks[strategy] = rank
                ranks[strategy, default: []].append(rank)
                ranksByKind[evalCase.kind, default: [:]][strategy, default: []].append(rank)
            }

            let embeddingTop5 = embeddingRanking.prefix(5).map { "\($0.document.id)(\(String(format: "%.3f", $0.score)))" }
            print("[\(evalCase.kind.rawValue)] \(evalCase.label) — 질의: \"\(evalCase.query)\" 기대: \(evalCase.expectedDocumentID)")
            print("  substring top5: \(substringIDs.prefix(5))  (정답 순위: \((caseRanks["substring"] ?? nil).map { "\($0)" } ?? "없음"))")
            print("  embedding top5: \(embeddingTop5)  (정답 순위: \((caseRanks["embedding"] ?? nil).map { "\($0)" } ?? "없음"))")
            print("  hybridRRF top5: \(hybridIDs.prefix(5))  (정답 순위: \((caseRanks["hybridRRF"] ?? nil).map { "\($0)" } ?? "없음"))")

            // 세 전략 중 하나라도 Top-1을 놓쳤으면 "실패"로 보고 Top-5 + 코사인 유사도를 남긴다.
            let anyMiss = [caseRanks["substring"], caseRanks["embedding"], caseRanks["hybridRRF"]].contains { ($0 ?? nil) != 1 }
            if anyMiss {
                var detail = "\n[실패 상세] \(evalCase.label) — 질의: \"\(evalCase.query)\"\n"
                detail += "  정답: \(evalCase.expectedDocumentID)\n"
                detail += "  substring 순위: \((caseRanks["substring"] ?? nil).map { "\($0)" } ?? "없음"), top5: \(substringIDs.prefix(5))\n"
                detail += "  embedding 순위: \((caseRanks["embedding"] ?? nil).map { "\($0)" } ?? "없음"), top5(점수): \(embeddingTop5)\n"
                detail += "  hybridRRF 순위: \((caseRanks["hybridRRF"] ?? nil).map { "\($0)" } ?? "없음"), top5: \(hybridIDs.prefix(5))"
                failureDetails.append(detail)
            }
        }

        func printHitRates(_ ranks: [String: [Int?]], title: String) {
            print("\n=== \(title) ===")
            for strategy in ["substring", "embedding", "hybridRRF"] {
                let values = ranks[strategy] ?? []
                let total = values.count
                guard total > 0 else { continue }
                let top1 = values.filter { $0 == 1 }.count
                let top3 = values.filter { if let r = $0 { return r <= 3 } else { return false } }.count
                let top5 = values.filter { if let r = $0 { return r <= 5 } else { return false } }.count
                print("\(strategy): Top1 \(top1)/\(total) (\(String(format: "%.0f%%", 100.0 * Double(top1) / Double(total)))) · "
                    + "Top3 \(top3)/\(total) (\(String(format: "%.0f%%", 100.0 * Double(top3) / Double(total)))) · "
                    + "Top5 \(top5)/\(total) (\(String(format: "%.0f%%", 100.0 * Double(top5) / Double(total))))")
            }
        }

        printHitRates(ranks, title: "전체 히트율")
        for kind in EvalCase.Kind.allCases {
            printHitRates(ranksByKind[kind] ?? [:], title: "\(kind.rawValue) 히트율")
        }

        print("\n=== 실패 상세 (Top-1을 놓친 질의만) ===")
        if failureDetails.isEmpty {
            print("(없음 — 세 전략 모두 모든 질의에서 Top-1 성공)")
        } else {
            failureDetails.forEach { print($0) }
        }

        // 정성적 기대: shortKeyword보다 naturalLanguage에서 embedding이 substring에 비해 상대적으로
        // 더 유리해야 한다(어휘 일치가 없을 가능성이 높은 유형이므로) — 다만 이번엔 파라미터를
        // 튜닝하지 않기로 했으므로, 강한 수치 기준 대신 "embedding이 substring보다 나쁘지는 않다"는
        // 느슨한 방향성만 확인한다.
        let naturalSubstringTop1 = (ranksByKind[.naturalLanguage]?["substring"] ?? []).filter { $0 == 1 }.count
        let naturalEmbeddingTop1 = (ranksByKind[.naturalLanguage]?["embedding"] ?? []).filter { $0 == 1 }.count
        XCTAssertGreaterThanOrEqual(naturalEmbeddingTop1, naturalSubstringTop1, "자연어 의미 검색에서 embedding의 Top-1이 substring-only보다 나쁘면 안 된다")
    }

    /// `matchRatio`(일치한 질의 토큰 수 / 전체 질의 토큰 수)를 같이 돌려준다 — RRF가 "단어 1개만
    /// 우연히 겹쳐도 후보 중 유일하게 순위가 매겨졌다는 이유만으로" 과도한 가중치를 주는 문제를
    /// 고치려면, 순위(rank)뿐 아니라 그 순위가 얼마나 부실한 근거로 매겨졌는지도 알아야 한다.
    /// (RRF 재설계 경위는 git 이력 참고 — 이번 재평가에서는 이 로직을 그대로 고정한다.)
    private static func substringRanking(query: String, corpus: [Document]) -> [(document: Document, matchRatio: Double)] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let scored = corpus.compactMap { doc -> (Document, Int)? in
            let haystack = doc.indexedText.lowercased()
            let score = tokens.filter { haystack.contains($0) }.count
            return score > 0 ? (doc, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { (document: $0.0, matchRatio: Double($0.1) / Double(tokens.count)) }
    }

    /// 코사인 유사도(`score`)도 같이 돌려준다 — "1위가 2위를 근소하게 이겼는지, 압도적으로
    /// 이겼는지"는 rank만으로는 안 보인다. 실패 원인 분석에 이 점수 차가 핵심 증거였다(CLAUDE.md
    /// "semantic Top-1 실패 원인 분석" 절 참고).
    private static func embeddingRanking(
        queryEmbedding: [Double],
        docEmbeddings: [String: [Double]],
        corpus: [Document]
    ) -> [(document: Document, score: Double)] {
        let scored = corpus.map { doc -> (Document, Double) in
            let docEmbedding = docEmbeddings[doc.id] ?? []
            let similarity = zip(queryEmbedding, docEmbedding).reduce(0.0) { $0 + $1.0 * $1.1 }
            return (doc, similarity)
        }
        return scored.sorted { $0.1 > $1.1 }.map { (document: $0.0, score: $0.1) }
    }

    /// **재설계된 형태를 그대로 고정한다(이번 재평가에서 추가 튜닝 안 함, 사용자 지시).** 예전
    /// 단순 버전은 substring이 "후보 목록에 유일하게 있다"는 이유만으로 `1/(k+1)`을 그대로 다
    /// 줬다 — 질의 토큰 여러 개 중 1개만 우연히 겹쳐도, 토큰이 전부 겹친 진짜 일치와 같은 rank-1
    /// 보너스를 받는 문제가 있었다(실제 실패 사례는 git 이력의 재설계 커밋 참고). 지금 버전은
    /// substring 쪽 기여도에 `matchRatio`를 곱해서 부분 일치가 전체 일치와 같은 보너스를 받지
    /// 않게 하고, `k=5`로 순위 차이를 더 크게 반영한다.
    private static func rrfRanking(
        _ substringRanking: [(document: Document, matchRatio: Double)],
        _ embeddingRanking: [(document: Document, score: Double)],
        corpus: [Document],
        k: Double
    ) -> [Document] {
        var scores: [String: Double] = [:]
        for (rank, entry) in substringRanking.enumerated() {
            scores[entry.document.id, default: 0] += entry.matchRatio * (1.0 / (k + Double(rank + 1)))
        }
        for (rank, entry) in embeddingRanking.enumerated() {
            scores[entry.document.id, default: 0] += 1.0 / (k + Double(rank + 1))
        }
        return corpus.sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
    }
}
