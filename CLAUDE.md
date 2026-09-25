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

**검색은 BROWSE-01 하단 검색창과 HOME-01 상단 검색창 둘 다에 있다(HOME-01 쪽은 2026-09-25 추가
— 처음엔 사용자 결정으로 안 넣었다가 나중에 원해서 붙였다).** `Networking/SearchAPIClient`(서버 `/v1/search/prepare` 호출, Job 아님 — 동기 요청/응답)가 자연어 질의를 해석·임베딩만 받아오고, `Services/SearchRanking`(순수 함수)이 로컬 DB에서 키워드(lexicalTerms가 OCR/searchText에 포함)+코사인 유사도를 단순 합산해 정렬한다 — 결합 방식은 기능명세서 자체가 "샘플 평가 후 결정"이라 명시한 미정 항목이라 잠정치다. `Services/SearchService`(actor)가 이 둘을 조합한다. `BrowseViewModel.search()`가 요청마다 UUID를 발급해 스테일 가드(SEARCH-09: 늦게 끝난 이전 요청이 최신 결과를 덮어쓰지 않게)를 구현한다. **폴더 범위 검색(SEARCH-04)은 폴더 기능과 함께 붙었다** — `BrowseScope`가 `.folder`면 `search()`가 `folderID`를 같이 넘긴다.
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

**아직 없는 것**: `folder_criteria` Job(모호한 폴더 기준을 AI가 다듬어주는 것 — 지금은 사용자가
적은 기준 텍스트를 그대로 씀), BROWSE-01 폴더 전환 줄, masonry 그리드, 앱이
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

**⚠️ 실제로 겪은 버그 — "다시 분석하기"가 영원히 같은 결과만 돌려줌 (2026-09-25 발견·수정).**
`ContentAnalysisService`의 Idempotency-Key가 `capture.id`+`content_revision`만으로 만들어져서,
실패 후 재시도가 서버 입장에서 "완전히 같은 요청"이 돼버렸다 — 서버(`JobService.submitContentAnalysis`)는
같은 키로 온 요청은 기존 job을 그대로 돌려주고 재실행하지 않는 게 원래 의도한 동작(멱등성)인데,
"재시도"는 의미상 "이전과 다른, 새로 해보고 싶은 요청"이라 이 규칙과 충돌했다. 실제로 9월 22일
트랜잭션 타이밍 버그(서버 CLAUDE.md 참고) 당시 만들어져 영원히 QUEUED로 멈춰있던 job 3개가
있었는데, 그 캡처들을 재시도할 때마다 서버가 그 멈춘 job을 그대로 돌려주기만 해서 클라이언트가
30번 폴링 후 `timedOut`으로 실패했다 — **서버 job 테이블엔 새 행이 하나도 안 생기는데 앱은
계속 실패하는** 상태라 원인 파악이 오래 걸렸다(diag 진단용 job을 curl로 직접 넣어 서버 자체는
멀쩡함을 먼저 확인하고 나서야 클라이언트의 키 재사용 문제라는 걸 알아냈다). `Capture.analysisAttempt`
(새 필드, `v2` 마이그레이션)를 추가해 `AnalysisQueueService.retry()`가 호출될 때만 증가시키고,
Idempotency-Key에 포함시켜 고쳤다 — `resumeIfNeeded()`가 pending 캡처를 처음(또는 앱이 죽어
processing에서 되돌아온 뒤 다시) 집을 때는 attempt를 올리지 않는다(그 경우엔 서버에서 여전히
진행 중이었을 수 있는 작업과 같은 키를 유지해야 중복 제출을 피한다 — 원래 멱등성 의도는 그대로
살림). `AnalysisQueueServiceTests`에 재시도마다 키가 달라지는 것, 자동 큐 재개는 키가 안 바뀌는
것 둘 다 회귀 테스트로 고정해뒀다.

**AI-03 자동 분류가 붙었다 (2026-09-25).** 서버에 새로 생긴 `classification` Job kind(서버
CLAUDE.md "자동 분류" 절)를 실제로 호출하는 클라이언트 쪽 — `Networking/ClassificationAPIClient`
(+`URLSessionClassificationAPIClient`, `POST /v1/jobs` JSON 바디)와 `Services/ClassificationService`
(actor, 제출→폴링→`FolderStoring.applyAutoMatch` 반영, `ContentAnalysisService`와 같은 구조)가
새로 생겼다. `AnalysisQueueService`가 이 둘을 잇는다:
- 분석이 성공하면(`analyzeOneCapture`) **같은 실행에서 바로 이어서 분류까지** 돈다 — 사용자가
  분류를 따로 트리거할 필요가 없다는 제품 방향(§1.4)에 맞춘다. 분류 실패는 `try?`로 삼켜서
  분석 자체의 성공 여부(재시도 버튼 등 호출자 관점)에 영향을 안 준다.
- `nextPendingForClassification()`(새 쿼리: `searchState=ready AND classificationState=pending`)이
  이 기능이 생기기 전에 이미 분석만 끝나 있던 캡처도 `resumeIfNeeded()`의 두 번째 루프에서 마저
  잡아준다.
- `ClassificationService.classify()`는 사용자가 만든 폴더 전부를 서버에 보낸다. **기준
  텍스트(`criteriaText`)를 안 적은 폴더는 폴더 이름(`displayName`)을 그 대신 기준으로 쓴다**
  (`effectiveCriteria(for:)`, 2026-09-25 사용자 결정) — 기능명세서 §3.3.1이 원래 그리던
  "사용자가 명시한 기준 우선, 표시 이름만으로 덮어쓰지 않음"에서 한 걸음 물러난 잠정 절충이다:
  기준 입력을 귀찮아하는 사용자가 많을 거라는 판단으로, 이름만으로도 일단 분류가 되게 했다.
  모호한 이름("중요" 등)을 잘못 판단할 위험은 별도 안전장치 없이 서버 프롬프트의 "직접 근거 없으면
  uncertain" 규칙에만 기댄다 — 실제로 얼마나 잘 걸러지는지는 아직 실증 전이다. **폴더가 하나도
  없으면 네트워크를 아예 안 탄다** — `SearchService`가 임베딩 버전 없을 때 서버를 안 부르는 것과
  같은 절약 패턴. `match` 판정만 `applyAutoMatch`로 반영하고(스테일 기준 버전·사용자 직접 소속
  보존은 이미 구현돼 있던 그 메서드가 알아서 함), `no_match`/`uncertain`은 아무 것도 안 한다.
- `CaptureStoring`에 `fetchAnalysis(for:)`를 다시 추가했다 — DETAIL-01/Live Text 작업 때 안 쓰게
  돼서 지웠던 그 메서드인데, 이번엔 다른 목적(분류가 OCR·관찰 내용을 읽어야 함)으로 다시 필요해졌다.
- **DETAIL-01의 "다시 분석하기" 버튼을 ready(성공) 상태에서도 보이게 넓혔다**(2026-09-25 사용자
  결정) — 원래는 `searchState == .failed`일 때만 보였는데, "폴더를 새로 만든 뒤 기존 캡처를 다시
  분류해보고 싶다"는 요구가 있어서 실패가 아니어도 사용자가 원하면 처음부터(content_analysis
  포함) 다시 돌릴 수 있게 했다. `AnalysisQueueService.retry()`/`CaptureDetailViewModel.retry()`
  자체는 원래도 시작 상태를 안 가렸어서(코드 변경 없음), `CaptureDetailView`의 표시 조건만 바꿨다
  — 캡처 하나씩만 되고 매번 실제 content_analysis(비용 발생)를 다시 돌린다. RECLASS-01(아래
  절, 폴더 단위 일괄 재분류·content_analysis 재실행 없음)이 생긴 지금은 "폴더 하나를 통째로
  다시 훑고 싶을 때"는 RECLASS-01 쪽이 훨씬 싸다 — 이 버튼은 "이 캡처 하나만 처음부터 다시"가
  필요할 때만 쓰는 용도로 남는다.

**아직 안 된 것**: 이 기능 자체를 위한 iOS 시뮬레이터 실기 검증(아래 참고), `folder_criteria`
Job(모호한 폴더 기준을 AI가 다듬어주는 것), FOLDER-06 자동 분류 교정 UI.

**⚠️ 실제로 겪은 버그 — classification Idempotency-Key가 재분석 후 재분류를 409로 막음
(2026-09-25 발견·수정).** content_analysis의 Idempotency-Key 버그(위 절)를 고친 뒤에도 비슷한
문제가 classification 쪽에 남아있었다: 키가 `capture.id`+`analysis_revision`으로만 만들어져서,
"다시 분석하기"로 content_analysis를 재실행했을 때 Gemini의 OCR·관찰 내용 문구가 이전 실행과
토씨까지 완전히 같다는 보장이 없어 — 조금이라도 다르면 서버가 "같은 키, 다른 요청 내용"으로
보고 `409 IDEMPOTENCY_CONFLICT`를 던졌다. 실제로 캡처 하나를 재분석했을 때 content_analysis는
성공(searchState=ready)했는데 classification만 "분류 보류"로 떨어지는 것으로 나타났다 — 서버
job 테이블에서 이전 분류 성공 기록(같은 키)과 새 재분석 시도를 대조해서 알아냈다.
`ClassificationService.classify()`가 `capture.analysisAttempt`(content_analysis 재시도 때
쓰는 바로 그 값)를 키에 같이 넣도록 고쳤다 — "다시 분석하기" 한 번이 content_analysis·
classification 두 키를 함께 새롭게 만든다. `ClassificationServiceTests`에 attempt가 키에
반영되는지 회귀 테스트로 고정했다.

**검증 이력 (2026-09-25, AI-03 추가·재분석 버그 수정 후)**: 테스트 126개 전부 통과. **시뮬레이터에서
실제로 폴더 자동 분류가 동작하는 것까지 확인했다** — "운세" 폴더(기준 텍스트 없이 이름만)를
만들고 분석 완료된 캡처에 자동 큐가 실제 Gemini classification 호출까지 보내는 것을 서버
job 테이블로 확인. 위 Idempotency-Key 버그도 이 검증 과정에서 실제로 재현·발견했다.

**RECLASS-01 재분류 확인이 붙었다 (2026-09-25).** ERD가 처음부터 갖고 있던 `ReclassificationRun`/
`ReclassificationItem` 모델(§2)을 이번에 처음 실제로 썼다 — GRDB 테이블도 v1 마이그레이션에
이미 있었는데 아무도 안 썼던 것들이다. `Persistence/ReclassificationStoring`
(+`GRDBReclassificationStore`), `Services/ReclassificationService`(actor, preview→apply/cancel),
`Features/Folder/ReclassificationView`·`ReclassificationViewModel`이 새로 생겼다.

**content_analysis는 다시 안 돌린다** — 기능명세서 §3.3.2 "기존 검색·분석 정보를 재사용한다"대로,
이미 저장된 OCR·관찰 내용으로 폴더 하나의 기준과만 다시 비교한다. `ClassificationService.classify(_:)`
(캡처 하나·전체 폴더)와 별도로 `evaluateSingleFolder(capture:folder:)`(캡처 하나·폴더 하나, 반영은
안 하고 판정만 돌려줌)를 추가해서 제출→폴링 로직만 공유한다.

**흐름**: `ReclassificationService.preview(folderID:mode:)`가 (1) 같은 폴더에 확정 안 된 실행이
있으면 `alreadyInProgress`로 막고(화면설계서 §11 "중복 실행 방지"), (2) 폴더의 현재
`criteriaVersion`·`membershipRevision`을 고정한 `ReclassificationRun`을 만들고, (3) 분석 완료된
캡처 전체(`CaptureStoring.fetchAnalyzedCaptures()`, 신규)를 이 폴더 기준으로 한 장씩 다시
판정해서 `ReclassificationItem`(add/remove)을 계산한다. **캡처 수만큼 실제 Gemini 호출이 나간다**
— 화면 진입 자체(폴더 메뉴의 "재분류", 생성 시트의 "기존 캡처에도 적용")가 이미 명시적 트리거라
별도 확인 알럿은 안 뒀다. 캡처 하나의 판정이 실패해도(예: 503) 전체를 포기하지 않고 다음 캡처로
넘어간다(`try?`로 삼킴) — AnalysisQueueService의 "실패해도 다음으로" 패턴과 같다.

**사용자 직접 소속은 항상 보존한다(§11 핵심 규칙)**:
- `match`인데 `blocked+manual`(사용자가 직접 뺌) → 추가 후보에서 아예 제외.
- `no_match`/`uncertain`인데 `present+manual`(사용자가 직접 넣음) → 제거 후보에서 아예 제외.
- 실제 "제거"는 `FolderStoring.applyAutoMismatchRemoval(captureID:from:criteriaVersion:)`(신규)이
  한다 — `applyAutoMatch`와 대칭이지만, "제거"를 `blocked`로 표현하지 않고 **행을 그대로 지운다**.
  `FolderCapture.state`는 ERD상 present/blocked 두 값뿐인데, blocked는 "사용자가 명시적으로 막음
  (향후 영구히 재매치 금지)"이라는 의미라 AI가 재분류로 뺀 것과 구분이 안 되기 때문 — 행이
  없으면 그냥 비소속이고, 나중에 진짜 다시 매치되면 `applyAutoMatch`가 자유롭게 다시 넣을 수 있다.

**두 진입점이 화면·뷰모델을 공유한다**(`ReclassificationTarget`으로 구분): FOLDER-01 폴더 스와이프
액션 "재분류"(`mode=.reclassify`), 새 폴더 생성 시트의 "기존 캡처에도 적용" 토글(`mode=.initialApply`,
`.create` 모드에서만 보임 — §10.2 "직접 생성 시 선택"). `FolderEditViewModel.onSaved`가
`(Folder, Bool)`로 바뀌어서 저장된 폴더와 "이어서 RECLASS-01을 열지" 여부를 같이 넘긴다.

**적용(apply)은 항목별로 독립적으로 처리한다** — 미리보기 이후 폴더 기준이 바뀐 항목은
`applyAutoMatch`/`applyAutoMismatchRemoval`의 스테일 가드가 그 항목만 조용히 건너뛰고(`skipped`),
나머지는 정상 적용된다. 취소(`cancel`)는 기존 소속을 그대로 두고 실행만 `cancelled`로 남긴다 —
둘 다 해당 폴더의 재분류를 다시 시작할 수 있게 실행을 확정 상태로 돌려놓는다(그래야
`activeRun`이 다음 `preview()`를 막지 않는다).

**아직 안 된 것**: FOLDER-06(자동 분류 교정 UI, 재분류 없이 개별 항목만 빠르게 수정) — RECLASS-01의
전체 미리보기·확인 흐름과는 별개다. 실기기/시뮬레이터로 실제 재분류 성공 케이스(추가·제거가
정말 반영되는 것)는 이 세션에서 서버 Gemini 호출까지 포함해 아직 눈으로 확인 전이다(테스트는
Fake로 전부 통과).

**테스트 (16개 추가, 총 142개)**: `ReclassificationServiceTests`(8, 미리보기 계산 규칙·중복 실행
방지·부분 실패 내성·적용/취소), `PersistenceTests`에 `fetchFolder`·`applyAutoMismatchRemoval`(3)·
`fetchAnalyzedCaptures`·`GRDBReclassificationStore` 라운드트립(6), `FolderEditViewModelTests`에
`applyToExistingCaptures` 전달 확인(2).

**HOME-01 상단 검색이 붙었다 (2026-09-25) — §7.1·§7.2를 뒤늦게 반영.** 처음엔 "HOME-01 상단 큰
검색영역은 이번엔 안 넣는다"고 결정했었는데(BROWSE-01 하단 검색창만으로 충분하다고 봤음),
사용자가 다시 원해서 추가했다. `HomeView`에 안내 문구·분석 진행 수·검색창을 한 덩어리로 두고
(§7.1 스케치 그대로 "어떤 캡처를 찾고 있나요?" → "N/M장 분석 완료" → 검색창), 검색을 실행하면
`.navigationDestination(item:)`으로 `BrowseView(scope: .all, ...)`를 새로 밀어 넣는다(§7.2:
"BROWSE-01에 전체 범위·입력 검색어를 전달한다. 홈에서 결과 카드를 펼치지 않음").

- `BrowseViewModel.init(initialQuery:)`(신규)가 넘겨받은 검색어로 `searchText`를 미리 채운다.
  빈 검색어 실행은 애초에 `HomeView.executeSearch()`가 걸러서 `pendingSearch` 자체를 안 만든다
  (§7.2: "빈 검색어 실행 | 검색 요청 없이 입력 유지").
- **`BrowseView`의 진입 로직을 이 김에 고쳤다** — `.task`가 `searchText`가 비어있는지 보고
  `load()`/`search()` 중 고르고, `.onAppear`(하위 화면에서 pop해 돌아왔을 때)는 `isSearchActive`면
  아예 아무것도 안 한다. 원래는 `.onAppear`가 무조건 `load()`를 다시 불러서, 검색 결과를 보다가
  DETAIL-01로 들어갔다 뒤로 가면 `isSearchActive`는 `true`로 남은 채 목록만 조용히 전체 목록으로
  되돌아가는 불일치가 있었다 — 화면설계서 §2 "뒤로 가면 검색어·폴더·스크롤 위치 복원"을 어기고
  있었던 셈이다. HOME-01 검색을 만들면서 바로 드러나 같이 고쳤다.
- 홈 검색창의 마지막 입력은 `@State`로만 유지한다(화면설계서: "마지막 홈 입력을 유지하는
  초안") — `NavigationStack`에서 자식을 pop해 돌아와도 `HomeView` 자체는 다시 안 만들어지니
  별도 저장 없이도 값이 남는다.

**테스트 (2개 추가, 총 144개)**: `BrowseViewModelTests`에 `initialQuery` 프리필·공백 무시 확인.

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

## 검색 온디바이스 전환 — Phase 1·2 진행 중 (2026-09-25)

검색을 서버(Gemini) 경유 없이 완전히 기기 안에서 처리하는 방향으로 전환하기로 했다(사용자
결정). **아직 기존 검색 경로(`SearchService`/`SearchAPIClient`/서버 `/v1/search/prepare`)는
전혀 안 건드렸다** — 새 코드는 전부 독립적으로 추가만 됐고, 평가(evaluation)로 품질을 확인한
뒤에야 기존 경로를 교체·제거하는 단계별 계획의 앞부분(Phase 1·2)만 진행한 상태다.

**Phase 1 완료 — `Services/LocalDateInterpreter.swift`.** "오늘·어제·이번 주·지난주·이번 달·
지난달·올해·작년"을 로컬에서 파싱해 날짜 구간(시작 포함·끝 미포함)과 남은 검색어로 분리한다.
띄어쓰기가 일관되지 않은 표기("이번 주"/"이번주")도 같이 받는다. 테스트 9개(월·연도 경계 넘는
경우, 자정 근처, 시작 포함·끝 미포함 확인 등) 전부 통과.

**Phase 2 — `NLContextualEmbedding`에서 ONNX Runtime 기반으로 방향 전환 (2026-09-25).**
처음엔 Apple `NLContextualEmbedding`(NaturalLanguage, iOS 17+)으로 구현했지만, 시뮬레이터에서
`filesystem error: in create_directories: Permission denied
["/var/db/com.apple.naturallanguaged/com.apple.e5rt.e5bundlecache"]`로 막혀 검증 자체가 안 됐다
(`_naturallanguaged` 시스템 계정 소유 디렉터리라 일반 권한으론 못 씀, CLI·Xcode GUI·시뮬레이터
2종 전부 동일 — Apple Developer Forums 스레드 #799951과 같은 증상, 알려진 OS/시뮬레이터 버그).
그 와중에 Android 출시 가능성이 논의에 들어오면서(사용자 결정) 애초에 OS가 내려주는 모델에
기대는 접근 자체를 재고했다 — `NLContextualEmbedding`은 iOS 전용이라 Android와 벡터 공간을
맞출 방법이 없었다.

**그래서 `intfloat/multilingual-e5-small`(MIT, 384차원, XLM-R 계열 토크나이저 + BERT 계열
인코더)을 ONNX 형식으로 앱 번들에 직접 넣고 ONNX Runtime Mobile로 돌리는 쪽으로 바꿨다** —
`Services/OnnxEmbeddingService.swift`. OS 에셋이 아니라 앱이 들고 다니는 고정 파일이라
시뮬레이터 캐시 권한 문제 자체가 없고, Android에서도 같은 `.onnx`를 ONNX Runtime Mobile로
돌리면 커널 차이 없이 동일 벡터가 나온다(Core ML/LiteRT로 각각 별도 변환하는 것보다 벡터 공간이
어긋날 위험이 적다는 게 크로스플랫폼 후보 비교 결론이었다).

- **번들 자산**: `CapPick/Resources/E5Small/`에 `model_quantized.onnx`(약 113MB, int8 동적
  양자화), `tokenizer.json`, `tokenizer_config.json`. **intfloat 원본 저장소가 아니라
  `Xenova/multilingual-e5-small`(HF, transformers.js 팀)에서 받았다** — intfloat 원본의 유일한
  int8 버전(`onnx/model_qint8_avx512_vnni.onnx`)은 이름 그대로 Intel AVX512-VNNI 전용으로
  양자화돼 있어 ARM(iOS·Android 둘 다)에 쓰기엔 위험 부담이 있었고, Xenova 버전은 브라우저
  WASM 실행을 전제로 애초에 하드웨어 독립적으로 양자화돼 있어 더 안전한 선택이었다.
- **의존성(`project.yml`)**: `microsoft/onnxruntime-swift-package-manager`(SPM, ONNX Runtime
  Mobile 공식 바인딩 — import는 `OnnxRuntimeBindings`, 패키지가 선언하는 라이브러리 product
  이름 `onnxruntime`과 실제 Swift 모듈 이름이 다르다는 걸 빌드 에러로 처음 알았다),
  `huggingface/swift-transformers`의 `Tokenizers` product(HF의 `tokenizer.json`을 그대로
  로드 — `AutoTokenizer.from(modelFolder:)`, Hub 네트워크 호출 없이 완전히 로컬로 동작).
- **⚠️ 실제로 겪은 버그 — XcodeGen이 리소스 폴더를 통째로 평평하게 만듦.** 처음엔
  `CapPick/Resources/E5Small`을 그냥 `sources: - path: CapPick`에 맡겼더니, 빌드된
  `.app` 안에 `E5Small/` 서브폴더 없이 `model_quantized.onnx`가 번들 루트에 그대로 흩뿌려졌다
  (`Bundle.main.url(forResource: "E5Small", withExtension: nil)`이 nil). XcodeGen이 일반
  그룹(노란 폴더)으로 다루면 내부 파일들을 개별 리소스로 펼쳐버리기 때문 — `project.yml`에서
  `CapPick` 소스 경로는 `Resources/E5Small`을 `excludes`로 빼고, 그 경로를 `type: folder`로
  별도 선언해서(파란 폴더 참조) 실제 디렉터리 구조가 번들 안에 그대로 보존되게 고쳤다.
- **모델 구조**: BERT 계열이라 `input_ids`/`attention_mask`/`token_type_ids` 3개를 받고
  `last_hidden_state`([1, seq_len, 384])만 내놓는다(`pooler_output` 없음, `onnx`/`transformers`
  Python 라이브러리로 그래프 입출력을 직접 확인함) — mean pooling(attention_mask 가중, 지금은
  배치 없이 한 번에 텍스트 하나만 처리해서 패딩이 없으니 항상 전부 1)과 L2 정규화를 서비스가
  직접 한다(모델 카드의 공식 `average_pool` 사용법과 동일). E5 관례대로 검색어는
  `"query: "`, 색인 대상 텍스트는 `"passage: "` 접두어를 붙인다(`OnnxEmbeddingInputKind`).
  `modelVersion`은 `NLContextualEmbedding` 때와 달리 고정 문자열
  (`"multilingual-e5-small-quantized-1"`)이다 — OS가 갱신할 수 있는 자산이 아니라 앱이 들고
  다니는 고정 파일이라, 벡터 공간이 바뀌는 유일한 경우는 이 번들 자산을 다른 버전으로 교체하며
  상수도 같이 올릴 때뿐이다.
- **테스트(`OnnxEmbeddingServiceTests`, 7개, 시뮬레이터에서 실제 모델로 전부 통과)**: 로드,
  차원 일관성(384), 결정론적 재현, L2 정규화(norm≈1), query/passage 접두어가 다르면 벡터도
  다름, 빈 텍스트 에러. **`testSemanticallySimilarTextsAreCloserThanUnrelatedOnes`가 이 모델을
  선택한 근거를 최소한으로 검증한다** — "사주 운세를 봤다"와 "오늘의 운세가 궁금해서 사주를
  봤다"(다른 표현, 같은 의미)의 코사인 유사도가 "파스타 맛집 데이트 코스 추천"(무관)보다 실제로
  높게 나왔다 — 다음 단계로 예정된 평가 하네스 전에 방향이 맞다는 걸 실제 값으로 먼저 확인.
- **아직 파악 안 한 것**: `onnxruntime-swift-package-manager`는 과거 "unsafe build flags"로
  App Store 제출 검증에 걸린 이슈가 있었고(최신 릴리스에서 고쳐졌다고 함, 지금 쓰는 1.24.2는
  이 문제 이후 버전) 커뮤니티 포크(`ntna141/onnxruntime-ios-swift-package`)가 따로 있을 정도로
  실제 제출 단계에서 다시 겪을 수 있다 — 지금은 제출을 안 하니 무시했지만, 나중에 Archive/제출
  단계에서 막히면 이 이슈부터 의심할 것. 추론 속도(시뮬레이터에서 첫 호출 포함 1.5~1.9초/건,
  모델 로드 캐싱 전 수치라 워밍업 후 실제 검색 지연은 이보다 짧을 가능성이 큼)도 실기기에서
  다시 재봐야 한다.
- **삭제함**: `NLContextualEmbedding` 기반이었던 `Services/OnDeviceEmbeddingService.swift`와
  `CapPickTests/OnDeviceEmbeddingServiceTests.swift` — 시뮬레이터 버그로 검증 자체가 막혀 있었고
  방향을 아예 바꿨으니 남겨둘 이유가 없다는 사용자 판단으로 지웠다(git 이력엔 남아있음).

## 검색 전략 평가 하네스 — `CapPickTests/SearchStrategyEvaluationTests.swift` (2026-09-25)

substring-only(현재 서버 검색 경로가 하는 것과 같은 어휘 일치) / embedding-only
(`OnnxEmbeddingService`만) / hybrid-RRF(둘을 Reciprocal Rank Fusion으로 결합) 세 전략을 같은
코퍼스·질의 29문서/18질의로 비교했다. **아직 `SearchService`에 아무것도 연결하지 않았다** —
Phase 3 진행 여부를 실제 데이터로 판단하기 위한 측정 전용 코드다. 코퍼스는 "문서엔 단어 A만
있는데 사용자는 의미가 같은 다른 단어 B로 검색한다"는 상황(사주→운세, 면접→인터뷰, 맛집→데이트
식당, 운영체제→OS, 원피스→옷)과, 반대로 "정확한 문자열 일치가 의미상 비슷한 다른 문서와 구분해
주는 근거인 경우"(브랜드/영수증, 운송장번호, 출구 번호, 에러 코드, 과목 코드, 장소명, 상품
모델명, 날짜 — 뒤 5개는 2026-09-25 사용자 요청으로 추가)를 같이 담는다.

**Top-1/Top-3/Top-5 히트율 (실제 온디바이스 모델로 측정, 시뮬레이터)**:

| 유형 | substring | embedding | hybridRRF |
|---|---|---|---|
| 전체(18) | Top1 83%·Top3 89%·Top5 89% | Top1 100%·Top3 100%·Top5 100% | Top1 100%·Top3 100%·Top5 100% |
| lexical(5, 어휘 겹침) | 100%/100%/100% | 100%/100%/100% | 100%/100%/100% |
| semantic(5, 다른 단어·같은 의미) | Top1 40%·Top3 60%·Top5 60% | 100%/100%/100% | 100%/100%/100% |
| exactStringFavoring(8, 정확한 문자열) | 100%/100%/100% | 100%/100%/100% | 100%/100%/100% |

**결론 1 — embedding 도입 근거는 실제 데이터로 확인됐다.** semantic 유형에서 substring-only는
Top-1의 60%를 놓친다(어휘가 하나도 안 겹치면 후보에서 통째로 빠짐 — 원리적 한계). embedding은
이 유형에서 Top-1 100%를 냈다("원피스→옷"처럼 상위어로 검색하는 어려운 케이스까지 포함).

**결론 2 — exact-string-favoring 8개 전부 embedding-only가 Top-1을 맞췄다, 그런데 "맞았다"의
질이 다르다.** 처음 3개(브랜드/운송장번호/출구번호)는 그냥 잘 맞았다. 2026-09-25에 사용자 요청으로
"나머지 문맥은 거의 동일하고 숫자·고유명사 한 글자만 다른" 5개 쌍을 더 넣었다 — 503 에러 로그
vs 504 에러 로그, CS101 vs CS201 중간고사 공지, 속초 vs 속리산 여행 사진, 아이폰 15 프로 vs
14 프로 가격, 9월 25일 vs 26일 회의록. **결과: 이 5개 중 숫자/모델명류 4개(에러 코드·과목
코드·상품 모델명·날짜) 전부에서, 헷갈리는 "쌍둥이" 문서가 정답 바로 다음 순위(2위)에 붙어
있었다** — 예를 들어 "503 에러" 질의에서 `error503`이 1위, `error504`가 바로 2위. 유일하게
장소명 케이스(속초 vs 속리산)만 쌍둥이가 top5 밖으로 밀려났다(공유하는 글자가 "속" 하나뿐이라
서로 다른 개념으로 더 뚜렷이 분리된 것으로 보인다).

**이게 왜 중요한가 — Top-1 정확도만 보면 놓치는 신호다.** 지금 코퍼스는 각 숫자 쌍이 정확히
2개뿐이라 "정답이 뭐든 2위 안에는 들어온다"라 Top-1이 안 깨졌다. 하지만 실제 캡처처럼 "503
에러"류 스크린샷이 여러 번 반복되고 OCR 텍스트도 지금처럼 깔끔하지 않다면(줄바꿈, 오탈자,
불필요한 UI 텍스트 섞임), 이 얇은 margin이 실제로 뒤집힐 가능성이 있다. **정확한 문자열이
핵심 근거인 질의(에러 코드·과목 코드·모델명·날짜류)는 embedding만으로는 불안하다는 근거가
됐다** — Phase 3에서 hybrid를 설계할 때, 이런 토큰(숫자·영문+숫자 조합·MM월DD일 패턴)을 감지해
substring 쪽 가중치를 올리는 것을 검토할 가치가 있다.

**결론 3(재설계 전) — 처음 짠 단순 RRF(k=60)는 semantic 유형에서 오히려 순수 embedding-only보다
Top-1이 나빴다(60% vs 100%).** 원인을 실제 사례로 추적함: "데이트하기 좋은 식당 추천" 질의에서
정답 문서(파스타 맛집)는 substring 후보 목록에 전혀 없었는데(어휘 완전 불일치, 그래서 RRF 점수
0), 완전히 무관한 문서("넷플릭스 추천...")가 우연히 "추천" 한 단어만 겹쳐 substring의 유일한
1위 후보가 되면서 RRF 합산 점수에서 정답을 앞질렀다("운영체제→OS" 케이스도 같은 패턴).

**RRF 재설계 완료 (2026-09-25) — 두 가지를 고쳤다.**
1. **substring 쪽 RRF 기여도에 `matchRatio`(일치 토큰 수/전체 토큰 수)를 곱한다.** 예전엔 "후보
   목록에 유일하게 있다"는 이유만으로 `1/(k+1)`을 전부 받았다 — 토큰 4개 중 1개만 우연히 겹쳐도
   토큰이 전부 겹친 진짜 일치와 같은 rank-1 보너스를 받는다는 뜻이었다. 이제 일치 비율만큼만
   받는다.
2. **`rrfConstant`를 60에서 5로 낮췄다.** k=60은 RRF 문헌의 표준값이지만 수천~수만 개 문서의
   깊은 순위에서 튜닝된 값이다 — k가 클수록 "1위와 4위 차이"를 작게 뭉갠다. 19문서짜리 이
   코퍼스에선 그 차이가 훨씬 큰 신호인데 k=60이 뭉개버려서, matchRatio를 곱해도 "정답 rank-1(
   embedding만) vs 무관한 문서 rank-1(substring, 희석됨)+rank-4(embedding)"의 합산에서 후자가
   근소하게 이기는 경우가 남아있었다. k=5로 낮추자 이 역전이 완전히 사라졌다.

**재설계 후 결과 — hybridRRF가 모든 유형에서 embedding-only와 동률(Top-1/3/5 전부 100%)까지
올라왔다.** `testCompareSearchStrategies`에 이 역전 케이스를 고정하는 회귀 방지 assert를
추가했다(hybridRRF의 전체 Top-1이 embedding-only보다 낮아지면 실패). **다만 정직하게 남겨야 할
한계**: 이 코퍼스에선 hybridRRF가 embedding-only보다 딱히 더 나은 걸 보여주지 못했다(둘 다
100%) — "hybrid가 embedding-only 대비 실제로 이득을 주는 사례"는 아직 이 평가에서 확인되지
않았다. matchRatio 가중·k=5도 19문서용 값이라, 실제 캡처 규모(수백~수천 건)로 다시 돌려봐야
이 결론(그리고 k값 자체)이 유지되는지 알 수 있다.

**아직 안 한 것**: `SearchRanking`의 RRF 전환(재설계는 끝났지만 실제 캡처 규모 재검증 전이라
그대로 옮기긴 이르다), 기존 검색 경로 교체·서버 코드 제거(Phase 3 이후), 더 큰 코퍼스(캡처
수백~수천 건 규모)로 재검증 — 특히 이번 k=5 튜닝과 "hybrid가 embedding-only보다 나은 사례가
아직 없다"는 두 발견이 큰 코퍼스에서도 유지되는지가 핵심. **이 서비스도 `SearchService`에는
아직 연결 안 했다** — 지금까지처럼 평가용으로 병행 존재하는 상태다.

## 현재 설정값 (모두 잠정치, 필요 시 `project.yml`에서 수정)

- Bundle ID: `com.cappick.ios` — 실제 배포용 Apple Developer 팀 도메인이 정해지면 교체
- 배포 타깃: iOS 17.0 — 기능명세서 §1은 "지원 OS 버전 미정"이라 임의로 정한 값
- `NSPhotoLibraryUsageDescription`이 Info.plist에 이미 들어있음 (PHOTO-01 사진 접근 권한에 필요)

## 지켜야 할 제약 (루트 CLAUDE.md 요약, 상세는 `../docs/cappick-plan-functional-spec-v0.11.md`)

- 캡처 제목·설명·태그를 보여주거나 편집하는 화면/모델을 추가하지 않는다.
- 검색은 입력 중이 아니라 "검색 실행" 시점에만 서버에 요청한다.
- 로그인 화면을 만들지 않는다. 설치 단위 자격(Installation)만 사용한다.
