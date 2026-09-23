# CapPick-ios

CapPick의 iOS 앱(SwiftUI). 제품 배경·기능 사양은 `../CLAUDE.md`와 `../docs/`를 먼저 참고한다.

## 현재 상태

XcodeGen 스캐폴딩 + `Models/`에 ERD v0.2 §2 로컬 엔터티를 그대로 옮긴 Swift 값 타입(Capture, CaptureAnalysis, SearchDocument, Folder, FolderCapture, LocalTask, ReclassificationRun, ReclassificationItem, AppStateEntry)까지 있다. `Persistence/`에는 GRDB(SQLite) 기반 로컬 DB와 `CaptureStoring`/`FolderStoring`/`AppStateStoring` store가 구현돼 있다.

첫 기능 조각으로 **사진 접근 → 스크린샷 발견 → 로컬 DB 등록**이 구현돼 있다(기능명세서 PHOTO-01~04·06, 화면설계서 ON-01~03, HOME-01 일부).
- `Services/ScreenshotLibrary`(사진 보관함 경계 프로토콜), `PhotosScreenshotLibrary`(Photos 프레임워크 구현), `ScreenshotSyncService`(발견한 스크린샷을 로컬 목록에 맞춤)
- `Features/Onboarding`(ON-01 시작 → ON-02 사진 접근 → ON-03 분석 시작), `Features/Home`(스크린샷 수·분석 진행만 보여주는 최소 홈)
- `App/AppEnvironment`(저장소·서비스 조립), `App/RootView`(온보딩 완료 여부로 화면 결정), 앱 복귀 시 새 스크린샷 재확인

**서버 통신도 연결돼 있다.** `Networking/`이 `CapPick-server`의 설치 검증 3개 엔드포인트를 실제로 호출하고, 앱이 로컬 DB와는 별개로 Keychain에 자격을 저장한다 — 자세한 내용은 아래 "설치 자격" 절 참고. **실제로 시뮬레이터에서 서버(로컬 `bootRun`)에 등록되는 것까지 확인했다** — 로그인 화면 없이 백그라운드에서 조용히 일어난다.

**BROWSE-01의 "빈 검색어" 흐름과 실제 검색(SEARCH-01·02·03·06·08·09)이 있다** — 검색어가 없으면 접근 가능한 캡처 전체를 최근순 2열 그리드로 보여준다(`Features/Browse`). 미분석(pending) 캡처도 함께 보인다(SEARCH-06). 썸네일은 `Services/ThumbnailLoading`(`PhotosThumbnailLoader`)이 `PHImageManager`로 가져온다. 지금은 정사각형 균일 그리드다 — 화면설계서가 요구하는 "이미지 비율에 따라 높이가 다른" masonry 배치는 다음 단계다(각 셀 코드에 명시해둠). `HomeView`의 폴더 카드(아래 "폴더 기능" 절)나 FOLDER-01 행을 눌러 진입한다.

**검색은 BROWSE-01 하단 검색창에 있다 — HOME-01 상단 큰 검색영역은 이번엔 안 넣었다(사용자 결정).** `Networking/SearchAPIClient`(서버 `/v1/search/prepare` 호출, Job 아님 — 동기 요청/응답)가 자연어 질의를 해석·임베딩만 받아오고, `Services/SearchRanking`(순수 함수)이 로컬 DB에서 키워드(lexicalTerms가 OCR/searchText에 포함)+코사인 유사도를 단순 합산해 정렬한다 — 결합 방식은 기능명세서 자체가 "샘플 평가 후 결정"이라 명시한 미정 항목이라 잠정치다. `Services/SearchService`(actor)가 이 둘을 조합한다. `BrowseViewModel.search()`가 요청마다 UUID를 발급해 스테일 가드(SEARCH-09: 늦게 끝난 이전 요청이 최신 결과를 덮어쓰지 않게)를 구현한다. **폴더 범위 검색(SEARCH-04)은 폴더 기능과 함께 붙었다** — `BrowseScope`가 `.folder`면 `search()`가 `folderID`를 같이 넘긴다.
- `GRDBCaptureStore.fetchSearchCandidates(capturedFrom:capturedBefore:folderID:)`가 `capture`+`captureAnalysis`+`searchDocument`(+`folderID`가 있으면 `folderCapture`까지) join으로 후보를 가져온다 — 분석 안 된 캡처는 애초에 후보가 아니다(INNER JOIN).
- `GRDBCaptureStore.currentEmbeddingModelVersion()`은 지금 서버 설정이 고정이라 분석 완료된 캡처는 전부 같은 임베딩 모델 버전일 거라고 가정하고 아무거나 하나를 돌려준다 — 하나도 없으면 nil이고, 이때 `SearchService`는 서버에 요청조차 안 보내고 바로 빈 결과를 돌려준다(검색 대상 자체가 없으므로).

**AI 분석 자동 큐가 붙어있다.** `Networking/JobAPIClient`(서버 `/v1/jobs` 제출·폴링)와
`Services/ContentAnalysisService`(캡처 한 장을 제출→폴링→로컬 저장, `Services/PhotosImageDataProvider`로
업로드용 JPEG 생성)가 한 장 처리를 담당하고, 그 위의 `Services/AnalysisQueueService`(actor)가
ON-03에서 동의한 뒤 pending 캡처를 **최근 것부터 순서대로 자동** 처리한다(AI-04/05/06) —
`HomeViewModel.refresh()`가 Home이 보일 때마다 깨우고(`resumeIfNeeded()`, 중복 실행 방지 내장),
진행률(`AnalysisProgress.searchPending`)이 0이 될 때까지 2초 간격으로 갱신한다. 재개는 새 상태 없이
`Capture.searchState`(pending/processing/ready/failed)만으로 이뤄진다 — 앱이 중간에 꺼져도
`resetStuckProcessing()`이 processing을 pending으로 되돌려 다음 실행에서 이어간다. 무한 재시도는
안 한다: 실패하면 failed로 남고 큐는 다음 캡처로 넘어간다. Browse 그리드의 ✨ 버튼은 이제 pending용이
아니라 **failed 캡처를 사용자가 직접 재시도**하는 용도(`arrow.clockwise` 아이콘)로 좁혀졌고
`BrowseViewModel`도 같은 방식으로 큐 진행을 폴링해 배지를 갱신한다.

**폴더 기능이 붙었다 (2026-09-23)** — `Features/Folder/`에 FOLDER-01(`FolderListView`·`FolderListViewModel`,
전체·미분류 시스템 행 + 사용자 폴더 목록·삭제·수정 진입)과 FOLDER-02(`FolderEditView`·`FolderEditViewModel`,
생성·이름/기준 수정 시트)가 있고, HOME-01은 이제 2열 폴더 카드(전체/미분류/사용자 폴더, 각각
`captureStore.fetchFolderCaptureCounts()`/`unclassifiedCount()`로 개수 표시)를 보여준다.
`FolderStoring`(전 세션에 이미 구현·테스트돼 있던 `save`/`fetchAll`/`delete`/`addManually`/
`removeManually`/`applyAutoMatch`)을 그대로 재사용했고, 새로 만든 건 UI와 카운트 조회 쿼리뿐이다.

- **`BrowseScope`**(`Features/Browse/BrowseViewModel.swift`) — `.all`/`.unclassified`/`.folder(Folder)`.
  `BrowseView`가 어디서 들어왔든(Home 카드, FOLDER-01 행) 같은 화면을 재사용하고, `load()`/`search()`
  둘 다 scope를 따른다.
- **MEMBER-01은 "한 장" 케이스만 있다** — 다중 선택 없이 `CaptureThumbnailView`의 `.contextMenu`로
  "폴더에 추가"(모든 폴더 서브메뉴, 이미 소속돼 있어도 다시 눌러도 안전) / "이 폴더에서 제거"
  (scope가 `.folder`일 때만) 두 동작뿐이다.
- **`Folder.criteriaState`는 항상 `.pending`으로 저장한다** — RECLASS-01, AI 자동 분류(AI-03)와
  그걸 실행할 `folder_criteria`/`classification` Job kind 자체가 서버에 없어서, 분류 기준 텍스트는
  지금은 그냥 사용자가 적어두는 메모일 뿐 아무것도 처리하지 않는다. 다만 `criteriaVersion`은
  기준이 실제로 바뀔 때만 올리도록 이미 맞춰뒀다(이름만 바꾸면 그대로) — 나중에 그 Job이 생겼을
  때 쓸 값이 지금부터 정확히 쌓이게 하려는 것.
- **폴더 이름 중복·길이 제한 없음** — 화면설계서가 스스로 "미정"이라고 한 항목이라 공백 이름만 막는다.
- BROWSE-01 안에서 폴더를 바로 전환하는 가로 스크롤 줄(화면설계서 §7.3)은 없다 — 폴더 전환은
  Home/FOLDER-01로 돌아가 다시 들어가는 것으로 대신한다.

**DETAIL-01 캡처 상세 화면이 붙었다 (2026-09-23)** — `Features/CaptureDetail/`에
`CaptureDetailView`·`CaptureDetailViewModel`. BrowseView의 `ForEach` 안에서
`CaptureThumbnailView`를 `NavigationLink`로 감싸서 진입한다(`CaptureThumbnailView` 자체는
안 건드림 — 기존 `.contextMenu` 롱프레스와 탭 내비게이션이 공존). 원본 화질은
`ThumbnailLoading.fullImage(for:)`(그리드 썸네일과 달리 `.aspectFit`, `PHImageManagerMaximumSize`)로
새로 불러온다. 즐겨찾기(`CaptureStoring.setFavorite`)·캡픽에서 제외(`exclude`, `excludedAt`만
채우고 원본은 안 건드림)도 이번에 처음 store에 생겼다 — 필드는 있었는데 아무도 안 썼었다.
소속 폴더 표시는 `FolderStoring.fetchFolders(containing:)`(`fetchMemberships(of:)`의 반대
방향, 이번에 추가). 제외 후 BROWSE-01/HOME-01로 돌아왔을 때 목록·카드 개수가 갱신되게
`BrowseView`/`HomeView`에 `.onAppear` 새로고침을 추가했다 — `NavigationStack`에서 자식을
pop해서 돌아오는 건 `.task`를 재실행 안 시켜서 따로 필요했다.

**DETAIL-03(글자 복사)은 서버 OCR이 아니라 애플 Live Text를 쓴다.** 처음엔 서버가 분석한
`CaptureAnalysis.ocrText`를 화면에 띄우고 복사 버튼을 다는 식으로 만들었는데, 사용자가 그보다
사진 앱에 이미 있는 Live Text(길게 눌러 이미지 위에서 바로 글자 선택·복사, iOS 15+ 시스템
기능)가 낫겠다고 해서 바꿨다. `Features/CaptureDetail/LiveTextImageView.swift`
(`UIViewRepresentable`, `VisionKit.ImageAnalyzer` + `ImageAnalysisInteraction`)가 이미지
위에 사진 앱과 똑같은 텍스트 선택 UI를 올린다 — 기기에서 즉시 되고 분석 대기/실패 상태에서도
쓸 수 있다. 이 때문에 `CaptureStoring.fetchAnalysis(for:)`(만들었다가 안 쓰게 돼서 다시 지움)와
`CaptureDetailViewModel.ocrText`/`copyText()`가 없다 — 서버 OCR은 이제 검색(`SearchRanking`,
`fetchSearchCandidates`가 직접 join)에만 쓰인다.
**실기기 특유의 버그를 하나 겪었다**: `UIViewRepresentable`가 감싼 `UIImageView`는 기본적으로
원본 이미지의 고유 크기(픽셀 크기)를 그대로 쓰려고 해서, 큰 스크린샷을 열면 화면 너비를
무시하고 원본 크기로(3배 이상 확대되고 잘린 채) 렌더링됐다 — `.aspectRatio` 수정자만으로는
안 고쳐졌다. `LiveTextImageView.sizeThatFits(_:uiView:context:)`(iOS 16+ `UIViewRepresentable`
API)를 오버라이드해서 SwiftUI가 제안한 크기를 그대로 쓰게 강제해야 했다 — 시뮬레이터에서
사용자가 실제로 발견해준 버그다.

**아직 없는 것**: FOLDER-01의 재분류(RECLASS-01)·AI 자동 분류(AI-03, folder_criteria/classification
Job kind가 서버에 없음), HOME-01 상단 큰 검색영역, BROWSE-01 폴더 전환 줄, masonry 그리드, 앱이
완전히 백그라운드로 전환됐을 때도 도는 진짜 백그라운드 처리(BGProcessingTask) — 지금은 포그라운드
에서만 순차 처리하고 멈추면 다음 포그라운드 진입 시 이어간다. 실패 이유를 "사진 접근/네트워크/
사용량 한도"처럼 세분화해 보여주는 것(AI-06)도 아직이다 — 지금은 실패했다는 사실과 재시도 버튼만
있다. ON-03의 AI 처리 안내 문구는 임시이며 공급자 선정 후 확정해야 한다. DETAIL-01의 확대·팬도
기본 핀치 스케일 수준이다(정교한 줌 뷰어 아님).

**검증 이력 (2026-09-23, 폴더 기능 추가 후)**: 테스트 104개(신규 `FolderListViewModelTests` 3개,
`FolderEditViewModelTests` 5개, `BrowseViewModelTests`에 scope·폴더 추가/제거·폴더 범위 검색 5개,
`PersistenceTests`에 카운트·폴더 범위 검색 저장소 메서드 3개) 전부 통과. 시뮬레이터에서 실제로
Home 카드→폴더 생성("+ 새 폴더")→롱프레스로 캡처를 폴더에 추가→같은 캡처를 폴더에서 제거까지
사용자가 직접 다 해봤고, 로컬 DB로 `folder.membershipRevision`과 `folderCapture.revision`이
`GRDBFolderStore.writeMembership`이 정확히 예상한 값(추가·추가·제거 순서로 3)까지 맞는 것을
교차 확인했다.

**검증 이력 (2026-09-23, DETAIL-01 추가 후)**: 테스트 113개 전부 통과. 시뮬레이터에서 사용자가
직접: 캡처 탭→상세 진입, Live Text로 이미지 속 글자 길게 눌러 선택(위 크기 버그 발견·수정 포함),
즐겨찾기 별 토글, 공유 시트(이 앱 첫 `UIActivityViewController`), 캡픽에서 제외→확인 알럿→
BROWSE-01로 복귀 후 목록에서 사라짐까지 전부 확인. 로컬 DB로 `capture.favorite`/`excludedAt`
값도 교차 확인함.

**검증 이력 (2026-09-22, 자동 큐 추가 후)**: 테스트 72개(신규 `AnalysisQueueServiceTests` 6개,
`PersistenceTests`에 큐 저장소 메서드 4개, `CaptureStoring` 프로토콜에 4개 메서드 추가) 전부 통과.
시뮬레이터에서 실제로 **온보딩 완료 후 앱을 열기만 했는데 탭 없이 캡처 3장이 자동으로 순서대로
처리되는 것까지 확인했다** — 로컬 DB를 직접 조회해 `processing → failed → (다음 캡처) processing`
순서로 넘어가는 걸 봤다(오늘 Gemini 무료 한도가 소진돼 있어서 셋 다 결국 `failed`로 끝났지만, 이건
외부 API 한도 문제고 큐 자체의 순차 진행·실패 시 다음으로 넘어가는 동작은 의도대로였다).

`CapPickTests/`에 테스트 53개(Persistence 18, 스크린샷 동기화 7, 온보딩·홈 ViewModel 9, 설치 자격 관련 12, API 클라이언트 5, Browse 2)가 있다. 화면설계서(`../docs/cappick-screen-spec-v0.8.md`)의 HOME-01 나머지, FOLDER-* 등을 이어서 구현하면 된다.

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

지금은 `Features/Onboarding`, `Features/Home`, `Features/Browse`, `Features/Folder`, `Features/CaptureDetail`, `Services/`, `Networking/`이 채워져 있고 나머지 `Features/*`(Analysis, Settings)는 빈 폴더다. XcodeGen은 파일이 있는 폴더만 프로젝트에 반영하므로, 폴더 안에 첫 파일을 추가한 뒤 `xcodegen generate`를 다시 돌려야 Xcode 네비게이터에 보인다. 테스트는 `CapPickTests/`(별도 타깃, `project.yml`에 정의)에 둔다.

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

`last-safe-server`가 `BusPositionClient` 인터페이스 뒤에 실제 공급자 구현체(`TagoBusPositionClient`)를 숨긴 것과 같은 이유: API 명세(`../docs/cappick-api-spec-v0.2.md`)가 "계약 초안"이라 바뀔 수 있고, 테스트에서는 실제 네트워크 없이 목(fake)으로 교체해야 한다. 실제로 구현된 첫 클라이언트가 `InstallationAPIClient`다.

```swift
// Networking/InstallationAPIClient.swift (실제 코드, 축약)
protocol InstallationAPIClient: Sendable {
    func requestChallenge() async throws -> ChallengeIssued
    func register(challengeId: String, keyId: String, attestationObject: Data) async throws -> InstallationRegistered
    func renewCredential(currentCredential: String, challengeId: String, assertionObject: Data) async throws -> CredentialRenewed
}
```

`URLSessionInstallationAPIClient`가 실제 구현체다. `CapPickJSON`에 인코더·디코더를 한 곳에 모아뒀다 — 서버가 전역으로 snake_case JSON(`spring.jackson.property-naming-strategy=SNAKE_CASE`)과 밀리초 단위 ISO-8601을 쓰기 때문이다. `ISO8601DateFormatter`는 Sendable이 아니라 static 공유 인스턴스로 두지 않고 호출마다 새로 만든다(Swift 6 동시성 검사기가 걸러냄 — 처음엔 static let으로 짰다가 컴파일 에러로 알게 됨). Job 등 다음 도메인 클라이언트도 같은 패턴(프로토콜 + `URLSession` 구현체, `CapPickJSON` 재사용)으로 `Networking/`에 추가한다.

테스트(`URLSessionInstallationAPIClientTests`)는 실제 네트워크 대신 `URLProtocol`을 스텁으로 등록해 요청 내용(경로·헤더·snake_case 바디)과 응답 파싱을 검증한다.

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

### 5. 설치 자격 — 서버와 짝이 맞아야 하는 부분

`CapPick-server/CLAUDE.md`의 "설치 검증(Installation / App Attest)" 결정과 반드시 같이 읽는다. 서버가 정한 3가지 결정(App Attest+개발용 우회, 불투명 랜덤 토큰, Apple 계정 미가입)이 iOS 쪽에도 그대로 이어진다.

- **`AttestationProvider`** — 서버 `AttestationVerifier`와 짝. `DevBypassAttestationProvider`(지금 실제로 쓰는 것)와 `AppAttestProvider`(`DCAppAttestService` 기반, 실기기+유료 계정 없이는 테스트 불가라고 클래스 상단에 명시해 둠)를 이 뒤에 숨긴다. `AppEnvironment.live()`에서 어느 쪽을 쓸지 한 곳에서 정한다 — Apple 계정이 생기면 거기만 바꾸면 된다.
- **`InstallationRegistrar`**(actor) — challenge 발급 → attestation/assertion 생성 → 서버 호출 → 자격 저장을 조합한다. 로그인 화면이 아니라 `RootView`가 앱 시작 시 백그라운드로 조용히 부른다(`try?`로 실패를 무시 — 서버가 꺼져 있어도 온보딩·홈 진입을 막지 않는다).
- **자격 저장은 Keychain, GRDB(AppState)가 아니다.** `CredentialStoring` / `KeychainCredentialStore`. ERD §2 AppState 주석("비밀 토큰은 이 테이블에 평문 저장하지 않는다")과 서버의 "credential은 해시만 저장" 결정을 클라이언트 쪽에서 지키는 방법이다. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`를 써서 다른 기기로 백업 이전되지 않게 했다 — 재설치 시 새로 등록하는 게 맞다는 전제(기능명세서 §3.9)와 맞다.
- **challenge 해시 방식이 서버와 정확히 일치해야 한다**: challenge 문자열의 UTF-8 바이트를 그대로 해시한다(base64 디코딩하지 않음) — `InstallationService.challengeBytes()`(서버)와 `InstallationRegistrar`/`AppAttestProvider`(iOS) 양쪽에 같은 코멘트로 남겨뒀다. 한쪽만 고치면 검증이 깨진다.
- 서버 URL은 지금 `http://localhost:8080` 하드코딩(`AppEnvironment.developmentServerURL`) — 로컬 개발 전용이고 배포 주소는 API 명세 §1 기준 아직 없다. 실기기 테스트는 Mac의 LAN IP로 바꿔야 한다.

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

**검증 이력 (2026-09-22, Networking 추가 후)**: 테스트 51개(추가된 12개는 설치 자격 관련 — `InstallationRegistrarTests`, `DevBypassAttestationProviderTests`, `KeychainCredentialStoreTests`, 5개는 `URLSessionInstallationAPIClientTests`) 전부 통과. **`CapPick-server`를 로컬에서 실제로 띄우고(`./gradlew bootRun`, bypass 모드) 앱을 시뮬레이터에 설치·실행해서 서버 DB에 `installation` 행이 실제로 생기는 것까지 확인했다.** 앱을 껐다 다시 켜도 중복 등록되지 않고(Keychain 캐시 재사용) 행 수가 그대로인 것도 확인했다 — 클라이언트-서버 통합이 처음으로 실제 동작한 지점이다.

**검증 이력 (2026-09-22, Browse 추가 후)**: 테스트 53개(추가된 2개는 `BrowseViewModelTests`) 전부 통과, 실기기 SDK 빌드 성공. `simctl addmedia`로 시뮬레이터 사진 보관함에 이미지 3장을 넣고, `simctl privacy grant photos`로 권한을 주고 앱을 재실행하니 **정상적으로 스크린샷 3장이 인식돼 로컬 DB에 등록됐다** — 처음엔 "addmedia로 넣은 이미지는 스크린샷 서브타입이 안 붙는다"고 잘못 추측했었는데, 실제로는 사진 접근 권한이 없어서 동기화 자체가 스킵된 것이었다(권한 부여 전엔 0장, 후엔 3장). **사용자가 시뮬레이터에서 직접 "전체 보기"를 눌러 스크린샷으로 그리드가 실제로 채워지는 것까지 확인해줬다** — 사주 앱, 컴퓨터 네트워크 강의 슬라이드, 알고리즘 문제 스크린샷 3장이 2열 그리드에 정상 렌더링됨. `PhotosThumbnailLoader`가 진짜 `PHAsset`에서 이미지를 그려내는 것까지 실증됐다.

**아직 확인 안 한 것**: ON-02(사진 권한 요청 창)·ON-03(분석 시작) 단계의 실제 탭 흐름, masonry(가변 높이) 레이아웃. CLI/AppleScript로는 화면을 안정적으로 탭할 수 없어(시뮬레이터 창을 AppleScript System Events가 못 잡음, 여러 번 시도했지만 실패) UI 테스트(XCUITest)도 아직 없다 — 필요하면 다음에 추가할 수 있다. 실제 App Attest(`AppAttestProvider`)는 Apple Developer 계정이 없어 전혀 테스트 못 했다. 시뮬레이터 창을 확대하고 사용자가 직접 탭하면 조작 자체는 가능하다는 걸 2026-09-22에 확인했다 — 창이 작으면(스케일 축소) 작은 탭 타깃이 자주 빗나간다.

**검증 이력 (2026-09-22, 검색 추가 후)**: 테스트 88개(신규 `SearchRankingTests` 5개, `URLSessionSearchAPIClientTests` 3개, `PersistenceTests`에 검색 후보 저장소 메서드 5개, `BrowseViewModelTests`에 검색 3개 — 스테일 가드 포함) 전부 통과. 시뮬레이터에서 검색창·"결과 없음" 상태까지 실제로 확인했다(사용자가 직접 검색어를 입력·실행). **다만 실제로 매칭되는 검색 결과는 아직 못 봤다** — 오늘 세션 내내 Gemini 무료 한도가 소진돼 있어서 분석이 성공적으로 끝난 캡처가 하나도 없었고(`searchDocument` 0행), `SearchService`가 이 경우 서버 호출도 없이 빈 결과를 돌려주는 것까지는 로컬 DB로 확인됐다. 분석이 실제로 한 장이라도 성공하면 그다음으로 키워드·의미 검색 결과 자체를 확인할 것.

## 현재 설정값 (모두 잠정치, 필요 시 `project.yml`에서 수정)

- Bundle ID: `com.cappick.ios` — 실제 배포용 Apple Developer 팀 도메인이 정해지면 교체
- 배포 타깃: iOS 17.0 — 기능명세서 §1은 "지원 OS 버전 미정"이라 임의로 정한 값
- `NSPhotoLibraryUsageDescription`이 Info.plist에 이미 들어있음 (PHOTO-01 사진 접근 권한에 필요)

## 지켜야 할 제약 (루트 CLAUDE.md 요약, 상세는 `../docs/cappick-plan-functional-spec-v0.11.md`)

- 캡처 제목·설명·태그를 보여주거나 편집하는 화면/모델을 추가하지 않는다.
- 검색은 입력 중이 아니라 "검색 실행" 시점에만 서버에 요청한다.
- 로그인 화면을 만들지 않는다. 설치 단위 자격(Installation)만 사용한다.
