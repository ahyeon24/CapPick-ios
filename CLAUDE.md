# CapPick-ios

CapPick의 iOS 앱(SwiftUI). 제품 배경·기능 사양은 `../CLAUDE.md`와 `../docs/`를 먼저 참고한다.

## 현재 상태

XcodeGen 스캐폴딩 + `Models/`에 ERD v0.2 §2 로컬 엔터티를 그대로 옮긴 Swift 값 타입(Capture, CaptureAnalysis, SearchDocument, Folder, FolderCapture, LocalTask, ReclassificationRun, ReclassificationItem, AppStateEntry)까지 있다. `Persistence/`에는 GRDB(SQLite) 기반 로컬 DB와 `CaptureStoring`/`FolderStoring`/`AppStateStoring` store가 구현돼 있다.

첫 기능 조각으로 **사진 접근 → 스크린샷 발견 → 로컬 DB 등록**이 구현돼 있다(기능명세서 PHOTO-01~04·06, 화면설계서 ON-01~03, HOME-01 일부).
- `Services/ScreenshotLibrary`(사진 보관함 경계 프로토콜), `PhotosScreenshotLibrary`(Photos 프레임워크 구현), `ScreenshotSyncService`(발견한 스크린샷을 로컬 목록에 맞춤)
- `Features/Onboarding`(ON-01 시작 → ON-02 사진 접근 → ON-03 분석 시작), `Features/Home`(스크린샷 수·분석 진행만 보여주는 최소 홈)
- `App/AppEnvironment`(저장소·서비스 조립), `App/RootView`(온보딩 완료 여부로 화면 결정), 앱 복귀 시 새 스크린샷 재확인

**아직 없는 것**: AI 분석·검색·폴더 화면·서버 통신(`Networking/`). ON-03의 "전체 캡처 분석 시작"은 지금은 `AppState`의 `analysisStartRequested`에 사용자 의사만 기록하고 등록된 캡처는 분석 대기(pending)로 남는다. 실제 분석 요청은 서버·AI 공급자 연동 후 붙인다. ON-03의 AI 처리 안내 문구는 임시이며 공급자 선정 후 확정해야 한다.

`CapPickTests/`에 테스트 34개(Persistence 18, 스크린샷 동기화 7, 온보딩·홈 ViewModel 9)가 있다. 화면설계서(`../docs/cappick-screen-spec-v0.8.md`)의 HOME-01 나머지, BROWSE-01 등을 이어서 구현하면 된다.

`Models/`의 일부 상태값(`SearchDocument.state`, `Folder.criteriaState`의 일부, `ReclassificationRun.state`, `ReclassificationItem.state`)은 ERD에 전체 값 집합이 명시돼 있지 않다 — 각 파일 주석에 근거와 "확정 전" 표시를 남겨뒀다. 서버 쪽 계약이 구체화되면 이 모델들도 같이 업데이트해야 한다.

## 프로젝트 구조

- `project.yml` — XcodeGen 스펙. **`.xcodeproj`를 직접 수정하지 말고 이 파일과 `xcodegen generate`로 관리한다.**
- `CapPick.xcodeproj` — `project.yml`에서 생성됨. 새 타겟/빌드 설정을 바꾸려면 `project.yml`을 고친 뒤 재생성한다.
- `CapPick/` — 소스 루트. 새 Swift 파일은 이 폴더(또는 하위 폴더) 안에 추가하면 XcodeGen이 자동으로 인식한다(파일마다 pbxproj를 손으로 편집할 필요 없음).

```
CapPick/
├── App/            — 앱 진입점, 루트 뷰
├── Features/       — 화면설계서 ID 기준 화면별 View + ViewModel
│   ├── Onboarding/   (ON-01~03)
│   ├── Home/         (HOME-01)
│   ├── Browse/       (BROWSE-01)
│   ├── CaptureDetail/(DETAIL-01)
│   ├── Folder/       (FOLDER-01·02, MEMBER-01, RECLASS-01)
│   ├── Analysis/     (ANALYSIS-01)
│   └── Settings/     (SETTINGS-01)
├── Models/         — ERD 로컬 엔터티에 대응하는 로컬 도메인 모델
├── Persistence/    — 로컬 DB 접근 (엔터티별 store 프로토콜)
├── Networking/      — 서버 /v1 API 클라이언트
└── Services/       — 화면에 안 묶인 도메인 로직 (분류 규칙, 검색 결합 등)
```

지금은 `Features/Onboarding`, `Features/Home`, `Services/`만 채워져 있고 나머지 `Features/*`, `Networking/`는 빈 폴더다. XcodeGen은 파일이 있는 폴더만 프로젝트에 반영하므로, 폴더 안에 첫 파일을 추가한 뒤 `xcodegen generate`를 다시 돌려야 Xcode 네비게이터에 보인다. 테스트는 `CapPickTests/`(별도 타깃, `project.yml`에 정의)에 둔다.

## 코딩 컨벤션

`last-safe-ios`는 README·`.gitignore`만 있고 실제 Swift 코드가 없어서 그대로 가져올 컨벤션이 없다. 대신 `last-safe-server`(같은 팀 프로젝트)의 코드에서 뽑은 원칙 — **경계는 프로토콜로 격리한다, 소속·필터 규칙은 호출부마다 반복하지 않고 한 곳에 캡슐화한다** — 을 Swift/SwiftUI 방식으로 옮겨서 CapPick-ios 자체 컨벤션으로 정한다. iOS 코드 자체를 베낀 게 아니라 같은 철학을 이 프로젝트 문서(화면설계서·ERD·시스템 설계) 기준으로 새로 적용한 것이다.

### 1. View는 얇게, 화면마다 ViewModel 하나

View는 상태를 보여주고 사용자 입력을 ViewModel로 전달만 한다. 분기·판단 로직을 View body 안에 두지 않는다. `@Observable`(Observation 프레임워크, iOS 17+)을 쓴다.

```swift
// Features/Home/HomeViewModel.swift
@Observable
final class HomeViewModel {
    private(set) var folders: [Folder] = []
    private(set) var analysisProgress: AnalysisProgress?

    private let folderStore: FolderStoring
    private let captureStore: CaptureStoring

    init(folderStore: FolderStoring, captureStore: CaptureStoring) {
        self.folderStore = folderStore
        self.captureStore = captureStore
    }

    func load() async {
        do {
            folders = try await folderStore.fetchAll()
            analysisProgress = try await captureStore.currentProgress()
        } catch {
            // 로드 실패 상태를 화면에 표시한다 (화면 구현 시 정의)
        }
    }
}
```

### 2. Networking — 서버 클라이언트를 프로토콜 뒤에 숨긴다

`last-safe-server`가 `BusPositionClient` 인터페이스 뒤에 실제 공급자 구현체(`TagoBusPositionClient`)를 숨긴 것과 같은 이유: API 명세(`../docs/cappick-api-spec-v0.2.md`)가 "계약 초안"이라 바뀔 수 있고, 테스트에서는 실제 네트워크 없이 목(mock)으로 교체해야 한다.

```swift
// Networking/CapPickAPIClient.swift
protocol CapPickAPIClient {
    func submitJob(_ request: JobSubmissionRequest) async throws -> JobSubmissionResponse
    func fetchJob(id: String) async throws -> JobStatusResponse
    func prepareSearch(_ request: SearchPrepareRequest) async throws -> SearchPrepareResponse
}

// Networking/URLSessionCapPickAPIClient.swift
final class URLSessionCapPickAPIClient: CapPickAPIClient {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
    }

    func submitJob(_ request: JobSubmissionRequest) async throws -> JobSubmissionResponse {
        // TODO: POST /v1/jobs (API 명세 §4). 설치 자격 헤더는 API 명세 §2 기준.
        fatalError("not implemented")
    }

    func fetchJob(id: String) async throws -> JobStatusResponse { fatalError("not implemented") }
    func prepareSearch(_ request: SearchPrepareRequest) async throws -> SearchPrepareResponse { fatalError("not implemented") }
}
```

### 3. Persistence — ERD 상태 규칙을 store 메서드 안에 캡슐화한다

서버 컨벤션의 `findByIdAndInstallation`과 같은 발상이다: "누가 볼 수 있는가"를 서버가 레포지토리 메서드에 캡슐화했듯, iOS에서는 "이 캡처가 실제로 어떤 목록에 보여야 하는가"라는 ERD의 상태 규칙을 ViewModel마다 다시 짜지 않고 store 메서드 이름에 그대로 박아 넣는다. 예를 들어 미분류 조회 규칙(ERD §3: "접근 가능 AND 제외 아님 AND 검색 준비 완료 AND 분류 complete AND present 관계 수=0")은 아래처럼 store 안에서 한 번만 구현한다.

```swift
// Persistence/CaptureStoring.swift (실제 코드)
protocol CaptureStoring: Sendable {
    func save(_ capture: Capture) async throws
    func fetchAll() async throws -> [Capture]            // "전체": 접근 가능 + 제외 아님
    func fetchUnclassified() async throws -> [Capture]   // ERD §3 미분류 조회 규칙을 여기서 한 번만 구현
    func fetch(in folder: Folder) async throws -> [Capture]
    func currentProgress() async throws -> AnalysisProgress
    func registerDiscovered(_ screenshots: [DiscoveredScreenshot]) async throws -> ScreenshotSyncResult
    // 새 자산은 pending으로 등록, 같은 자산은 재등록 안 함, 목록에서 사라지면 unavailable, 제외한 캡처는 되살리지 않음
}
```

호출하는 쪽(ViewModel)은 필터 조건을 다시 조립하지 않고 `fetchUnclassified()`만 부른다. 폴더 소속 규칙(ERD §3 표)도 마찬가지로 `FolderStoring` 안에 있다: `addManually`(present+manual, 차단 해제), `removeManually`(blocked+manual), `applyAutoMatch`(사용자가 직접 추가·제거한 관계, 기준 버전이 바뀐 늦은 결과, 접근 불가·제외 캡처는 반영하지 않고 이유를 `AutoMatchResult`로 돌려준다). 소속이 바뀔 때마다 폴더의 `membershipRevision`이 올라간다.

구현체는 `GRDBCaptureStore`, `GRDBFolderStore`이고 `AppDatabase`(`makeOnDisk()` / 테스트용 `makeInMemory()`)를 받는다. 앱 시작 시 `App/AppEnvironment.live()`가 `AppDatabase.makeOnDisk()`를 한 번 만들어 store·서비스에 주입하고, 화면(ViewModel)은 그걸 받아 쓴다.

### 4. 로컬 DB — GRDB(SQLite), 컬럼 이름은 Swift 프로퍼티 그대로

- 저장 기술은 GRDB로 정했다(2026-09-19 사용자 결정). 이유: `FolderCapture` 복합 키, "미분류" 같은 다조건 조회, 트랜잭션, 임베딩 저장을 SQL로 정확히 제어할 수 있고 `Models/`의 struct를 그대로 쓴다. SPM 패키지 `GRDB` 7.x(현재 7.11.1)를 `project.yml`의 `packages`로 관리한다.
- `Models/`의 struct는 `Codable`이고, `Persistence/Records.swift`에서 GRDB `FetchableRecord`/`PersistableRecord`를 붙인다. 모델 파일 자체는 GRDB를 import하지 않는다.
- 테이블·컬럼 이름은 프로퍼티 이름 그대로(camelCase: `photoAssetID`, `folderCapture` …)다. ERD의 snake_case는 논리 설계라 물리 이름은 미확정이었다.
- 스키마는 `AppDatabase`의 마이그레이션(`v1`)이 만든다. 스키마를 바꿀 땐 기존 마이그레이션을 고치지 말고 새 마이그레이션(`v2` …)을 추가한다.
- 벡터(`SearchDocument.embedding`)는 지금 JSON 텍스트로 저장한다 — 저장 방식은 시스템 설계 §9상 미정이고, 수천 장 기준 성능 검증 후 바꿀 수 있다.

### 가져오지 않은 것 / 아직 정하지 않은 것

- 로컬 DB 기술은 GRDB로 정했다(위 §4). 그래도 `Persistence/` 프로토콜은 구현체를 나중에 바꿔도 화면 코드가 안 바뀌게 하려는 경계로 유지한다.
- last-safe-server의 `assembly`(여러 도메인 결과 조립) 같은 패키지는 아직 대응 화면·기능이 없어서 만들지 않았다.

## 빌드/재생성 명령어

```bash
# project.yml을 바꾼 뒤 .xcodeproj 재생성
xcodegen generate

# 시뮬레이터에서 테스트 (iOS 26.3 런타임, iPhone 17 Pro 기준. `xcrun simctl list devices`로 id 확인)
xcodebuild test -project CapPick.xcodeproj -scheme CapPick \
  -destination 'platform=iOS Simulator,id=<기기 id>'
```

빌드·실행·테스트는 Xcode.app에서 직접 여는 것도 된다(`open CapPick.xcodeproj`, 테스트는 `Cmd+U`).

**검증 이력 (2026-09-19)**: iOS 시뮬레이터 런타임 설치 후 `xcodebuild test`로 테스트 34개(Persistence 18, 스크린샷 동기화 7, 온보딩·홈 ViewModel 9) 전부 통과했다. 앱을 시뮬레이터에 설치·실행해 ON-01 화면이 뜨고 `cappick.sqlite`에 테이블 9개가 생성되는 것까지 확인했다.

**아직 확인 안 한 것**: 화면을 눌러가며 하는 흐름(사진 권한 창, ON-02→ON-03 이동, 스크린샷 개수 표시). 시뮬레이터 사진 보관함에는 스크린샷이 없어서 스크린샷 발견은 스크린샷이 있는 실기기 아이폰에서 확인해야 한다. CLI에서는 화면을 탭할 수 없어 UI 테스트도 아직 없다.

## 현재 설정값 (모두 잠정치, 필요 시 `project.yml`에서 수정)

- Bundle ID: `com.cappick.ios` — 실제 배포용 Apple Developer 팀 도메인이 정해지면 교체
- 배포 타깃: iOS 17.0 — 기능명세서 §1은 "지원 OS 버전 미정"이라 임의로 정한 값
- `NSPhotoLibraryUsageDescription`이 Info.plist에 이미 들어있음 (PHOTO-01 사진 접근 권한에 필요)

## 지켜야 할 제약 (루트 CLAUDE.md 요약, 상세는 `../docs/cappick-plan-functional-spec-v0.11.md`)

- 캡처 제목·설명·태그를 보여주거나 편집하는 화면/모델을 추가하지 않는다.
- 검색은 입력 중이 아니라 "검색 실행" 시점에만 서버에 요청한다.
- 로그인 화면을 만들지 않는다. 설치 단위 자격(Installation)만 사용한다.
