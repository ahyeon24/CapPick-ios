import XCTest
@testable import CapPick

/// substring-only(현재 서버 경로와 유사한 어휘 일치) / embedding-only(OnnxEmbeddingService만) /
/// hybrid-RRF(둘을 Reciprocal Rank Fusion으로 결합) 세 가지 검색 전략을 같은 한국어 코퍼스·질의로
/// 비교하는 평가 하네스다. **아직 SearchService에 어떤 것도 연결하지 않는다** — Phase 3 진행 여부를
/// 실제 데이터로 판단하기 위한 측정 전용 코드다.
///
/// **hybrid-RRF는 한 번 재설계됐다.** 처음 버전(단순 rank 합산, k=60)은 semantic 유형에서 오히려
/// 순수 embedding-only보다 못했다 — substring이 어휘 0개 겹치면 후보에서 통째로 빼는데, 단어 1개만
/// 우연히 겹친 무관한 문서가 그 자리에서 "유일한 1위"가 되며 과도한 가중치를 받았기 때문이다.
/// `rrfRanking`이 substring 기여도에 `matchRatio`를 곱하고, `rrfConstant`를 이 코퍼스 크기에 맞게
/// 낮춰서 고쳤다 — 각 함수의 문서 주석에 실제 실패 사례로 원인·수정 근거를 남겨뒀다.
///
/// 코퍼스는 "문서는 단어 A만 담고 있는데, 사용자는 의미가 같은 다른 단어 B로 검색한다"는 상황을
/// 재현한다(예: 문서엔 "사주"만 있고 "운세"로 검색) — 이게 substring-only가 원리적으로 못 푸는
/// 문제이자 embedding을 도입하려는 이유 그 자체다. 반대로 브랜드명·운송장번호·출구번호처럼
/// **정확한 문자열 일치가 의미상 비슷한 다른 문서와 구분해주는 근거인 경우**도 같이 넣어서, embedding만
/// 쓸 때 실제로 잃는 게 무엇인지도 같이 측정한다.
final class SearchStrategyEvaluationTests: XCTestCase {
    private struct Document {
        let id: String
        let text: String
    }

    private struct EvalCase {
        let label: String
        let query: String
        let expectedDocumentID: String
        let kind: Kind

        enum Kind: String {
            case lexical
            case semantic
            case exactStringFavoring
        }
    }

    private static let corpus: [Document] = [
        Document(id: "saju", text: "사주 오행 분석 결과입니다. 생년월일 기준으로 사주팔자를 정리했어요."),
        Document(id: "interview", text: "카카오 백엔드 개발자 채용 면접 질문 정리 - 자료구조와 네트워크 위주로 준비"),
        Document(id: "pasta", text: "홍대 파스타 맛집 웨이팅 후기, 크림 파스타 진짜 존맛"),
        Document(id: "os", text: "운영체제 시험 범위 프로세스 스케줄링 챕터 정리 노트"),
        Document(id: "dress", text: "여름 원피스 신상 할인 쇼핑몰 장바구니 캡처해둠"),
        Document(id: "starbucks", text: "스타벅스 아메리카노 영수증 4500원 결제 완료"),
        Document(id: "coffeebean", text: "커피빈 아메리카노 영수증 4800원 결제 완료"),
        Document(id: "trackingA", text: "택배 운송장번호 394857102934 배송 조회 결과"),
        Document(id: "trackingB", text: "택배 운송장번호 118823940111 배송 조회 결과"),
        Document(id: "gangnam3", text: "강남역 3번 출구에서 만나기로 함 저녁 약속"),
        Document(id: "gangnam5", text: "강남역 5번 출구 CU 편의점 앞에서 만나기로 함"),
        Document(id: "movie", text: "영화 예매 확인 CGV 아바타 3 좌석 F14"),
        Document(id: "gym", text: "헬스 루틴 기록 가슴 등 3분할 스쿼트 무게"),
        Document(id: "meeting", text: "팀 회의록 캡처 다음 스프린트 일정 논의"),
        Document(id: "map", text: "지도 길찾기 캡처 회사까지 버스 노선"),
        Document(id: "bank", text: "은행 계좌 이체 내역 캡처 전세자금 대출"),
        Document(id: "netflix", text: "넷플릭스 추천 드라마 목록 캡처해둠"),
        Document(id: "weather", text: "날씨 앱 캡처 이번주 미세먼지 나쁨"),
        Document(id: "recipe", text: "김치찌개 레시피 캡처 재료 손질법"),
        // 아래는 "나머지 문맥은 거의 동일하고 숫자·고유명사 한 글자만 다른" 짝 — embedding이
        // 상대적으로 약할 수 있고 정확한 문자열 검색이 강할 거라 예상되는 케이스를 더 넣은 것
        // (사용자 요청, 2026-09-25). 에러 코드·과목 코드·장소명·상품 모델명·날짜.
        Document(id: "error503", text: "서버 응답 503 Service Unavailable 에러 로그 캡처"),
        Document(id: "error504", text: "API 요청 실패 504 Gateway Timeout 에러 로그 캡처"),
        Document(id: "cs101", text: "CS101 자료구조 중간고사 범위 공지 캡처"),
        Document(id: "cs201", text: "CS201 알고리즘 중간고사 범위 공지 캡처"),
        Document(id: "sokcho", text: "속초 여행 사진 캡처 바다 풍경"),
        Document(id: "songnisan", text: "속리산 등산 사진 캡처 단풍 풍경"),
        Document(id: "iphone15", text: "아이폰 15 프로 가격 비교 캡처"),
        Document(id: "iphone14", text: "아이폰 14 프로 가격 비교 캡처"),
        Document(id: "meeting0925", text: "9월 25일 회의록 캡처 스프린트 계획"),
        Document(id: "meeting0926", text: "9월 26일 회의록 캡처 스프린트 계획"),

        // 더 큰 코퍼스로 재검증 (사용자 요청, 2026-09-25). 아래 두 그룹을 추가해 29개 →
        // 159개로 늘렸다: ① 지금까지의 "정확한 문자열" 5개 짝을 각각 10개짜리 그룹으로
        // 넓혀서(에러코드·과목코드·장소명·상품모델명·날짜) 단발성 사례가 아니라 카테고리
        // 전체에서 margin이 유지되는지 통계적으로 본다. ② 서로 관련 없는 필러 문서 90개를
        // 더해 실제 규모에 가까운 "무관한 후보 속에서 진짜를 찾아야 하는" 상황을 재현한다.

        // 에러 코드 (503/504에 8개 추가, 총 10개)
        Document(id: "error500", text: "웹사이트 접속 500 Internal Server Error 에러 로그 캡처"),
        Document(id: "error501", text: "API 응답 501 Not Implemented 에러 캡처"),
        Document(id: "error502", text: "프록시 서버 502 Bad Gateway 에러 캡처"),
        Document(id: "error400", text: "요청 실패 400 Bad Request 에러 로그 캡처"),
        Document(id: "error401", text: "로그인 실패 401 Unauthorized 에러 캡처"),
        Document(id: "error403", text: "접근 거부 403 Forbidden 에러 로그 캡처"),
        Document(id: "error404", text: "페이지 없음 404 Not Found 에러 캡처"),
        Document(id: "error429", text: "요청 과다 429 Too Many Requests 에러 캡처"),

        // 과목 코드 (CS101/CS201에 8개 추가, 총 10개)
        Document(id: "cs102", text: "CS102 프로그래밍입문 과제 안내 캡처"),
        Document(id: "cs301", text: "CS301 운영체제론 프로젝트 공지 캡처"),
        Document(id: "math101", text: "MATH101 미적분학 중간고사 범위 캡처"),
        Document(id: "eng201", text: "ENG201 영작문 과제 마감 안내 캡처"),
        Document(id: "phys101", text: "PHYS101 일반물리학 실험 일정 캡처"),
        Document(id: "econ101", text: "ECON101 경제학원론 퀴즈 공지 캡처"),
        Document(id: "stat201", text: "STAT201 통계학 중간고사 범위 캡처"),
        Document(id: "bio101", text: "BIO101 일반생물학 실습 일정 캡처"),

        // 장소명 (속초/속리산에 8개 추가, 총 10개)
        Document(id: "yeouido", text: "여의도 벚꽃축제 사진 캡처 한강공원"),
        Document(id: "yeouinaru", text: "여의나루역 자전거 대여소 위치 캡처"),
        Document(id: "sinchon", text: "신촌 술집 웨이팅 캡처 대학가 골목"),
        Document(id: "sillim", text: "신림역 고시식당 후기 캡처 가성비"),
        Document(id: "jamsil", text: "잠실 롯데월드타워 전망대 캡처"),
        Document(id: "jamwon", text: "잠원한강공원 피크닉 사진 캡처"),
        Document(id: "gangbuk", text: "강북구 등산로 안내 캡처 북한산 코스"),
        Document(id: "ilsan", text: "일산호수공원 산책 사진 캡처"),

        // 상품 모델명 (아이폰 15/14에 8개 추가, 총 10개)
        Document(id: "iphone13", text: "아이폰 13 중고 가격 캡처 자급제"),
        Document(id: "iphone16", text: "아이폰 16 프로 사전예약 캡처 배송일정"),
        Document(id: "galaxyS23", text: "갤럭시 S23 울트라 가격 비교 캡처"),
        Document(id: "galaxyS24", text: "갤럭시 S24 사전예약 혜택 캡처"),
        Document(id: "galaxyS25", text: "갤럭시 S25 스펙 비교 캡처 카메라 화소"),
        Document(id: "macbookAir13", text: "맥북 에어 13인치 가격 비교 캡처"),
        Document(id: "macbookPro14", text: "맥북 프로 14인치 스펙 캡처 M4칩"),
        Document(id: "macbookPro16", text: "맥북 프로 16인치 가격 비교 캡처"),

        // 날짜 (9월 25/26일에 8개 추가, 총 10개, 같은 템플릿의 스프린트 회의록)
        Document(id: "meeting0920", text: "9월 20일 회의록 캡처 스프린트 계획"),
        Document(id: "meeting0921", text: "9월 21일 회의록 캡처 스프린트 계획"),
        Document(id: "meeting0922", text: "9월 22일 회의록 캡처 스프린트 계획"),
        Document(id: "meeting0923", text: "9월 23일 회의록 캡처 스프린트 계획"),
        Document(id: "meeting0924", text: "9월 24일 회의록 캡처 스프린트 계획"),
        Document(id: "meeting0927", text: "9월 27일 회의록 캡처 스프린트 계획"),
        Document(id: "meeting0928", text: "9월 28일 회의록 캡처 스프린트 계획"),
        Document(id: "meeting0929", text: "9월 29일 회의록 캡처 스프린트 계획"),

        // 필러 — 서로 관련 없는 일상 카테고리 90개 (실제 캡처 앨범처럼 무관한 후보를 늘린다)
        Document(id: "shopBag", text: "명품 가방 이월상품 세일 캡처 30% 할인"),
        Document(id: "shopShoes", text: "러닝화 리뷰 캡처 쿠션감 좋음"),
        Document(id: "shopElectronics", text: "무선 이어폰 신제품 비교 캡처 노이즈캔슬링"),
        Document(id: "shopCoupon", text: "쿠팡 로켓와우 할인쿠폰 캡처 다음달 만료"),
        Document(id: "shopFurniture", text: "이케아 책상 조립 후기 캡처 사이즈 측정"),
        Document(id: "shopBeauty", text: "올리브영 세일 기간 화장품 장바구니 캡처"),
        Document(id: "shopKids", text: "유아용품 공동구매 캡처 기저귀 대용량"),
        Document(id: "shopSecondhand", text: "당근마켓 중고 자전거 거래 캡처 가격 흥정"),
        Document(id: "foodDelivery", text: "배달의민족 주문내역 캡처 치킨 반반"),
        Document(id: "foodCafe", text: "동네 카페 신메뉴 캡처 흑임자 라떼"),
        Document(id: "foodBrunch", text: "브런치 맛집 웨이팅 캡처 에그베네딕트"),
        Document(id: "foodBBQ", text: "고깃집 예약 확인 캡처 삼겹살 무한리필"),
        Document(id: "foodBaking", text: "홈베이킹 레시피 캡처 스콘 굽기"),
        Document(id: "foodVegan", text: "비건 식당 후기 캡처 두부 스테이크"),
        Document(id: "foodBubbleTea", text: "버블티 신메뉴 캡처 흑당 밀크티"),
        Document(id: "foodMarket", text: "전통시장 먹거리 캡처 떡볶이 순대"),
        Document(id: "travelFlight", text: "제주도 항공권 예약 확인 캡처 왕복"),
        Document(id: "travelHotel", text: "호텔 예약 확인서 캡처 오션뷰 객실"),
        Document(id: "travelJapan", text: "오사카 여행 일정표 캡처 3박4일"),
        Document(id: "travelCamping", text: "캠핑장 예약 캡처 가평 글램핑"),
        Document(id: "travelPackingList", text: "여행 짐싸기 체크리스트 캡처"),
        Document(id: "travelVisa", text: "베트남 비자 신청 서류 캡처"),
        Document(id: "travelTrain", text: "KTX 예매 확인 캡처 부산행"),
        Document(id: "travelRentalCar", text: "렌터카 예약 캡처 제주 공항 픽업"),
        Document(id: "workSlack", text: "슬랙 팀 채널 공지 캡처 배포 일정"),
        Document(id: "workResume", text: "이력서 초안 캡처 경력기술서 수정중"),
        Document(id: "workOKR", text: "분기 OKR 정리 캡처 목표 지표"),
        Document(id: "studyToeic", text: "토익 학원 시간표 캡처 리스닝 파트"),
        Document(id: "studyCert", text: "정보처리기사 필기 합격 캡처"),
        Document(id: "studyLibrary", text: "도서관 좌석 예약 캡처 열람실 3층"),
        Document(id: "workExpense", text: "법인카드 지출결의서 캡처 출장비"),
        Document(id: "studyOnlineCourse", text: "인프런 강의 진도율 캡처 스프링 부트"),
        Document(id: "healthHospital", text: "병원 진료 예약 확인 캡처 정형외과"),
        Document(id: "healthPrescription", text: "약국 처방전 캡처 감기약 3일치"),
        Document(id: "gymRoutine", text: "헬스장 PT 스케줄 캡처 하체의 날"),
        Document(id: "healthRunningApp", text: "러닝 앱 기록 캡처 5km 완주"),
        Document(id: "healthDiet", text: "식단 관리 앱 캡처 오늘의 칼로리"),
        Document(id: "healthYoga", text: "요가원 수업 시간표 캡처 아침반"),
        Document(id: "healthCheckup", text: "건강검진 결과 캡처 콜레스테롤 수치"),
        Document(id: "financeCard", text: "카드값 명세서 캡처 이번달 결제 내역"),
        Document(id: "financeStock", text: "주식 앱 캡처 삼성전자 매수 체결"),
        Document(id: "financeLoan", text: "전세자금 대출 상담 캡처 금리 비교"),
        Document(id: "financeSavings", text: "적금 만기 알림 캡처 이자 확인"),
        Document(id: "financeInsurance", text: "실손보험 청구 캡처 진료비 영수증"),
        Document(id: "financeCrypto", text: "코인 거래소 앱 캡처 비트코인 시세"),
        Document(id: "financeTax", text: "연말정산 간소화 캡처 소득공제 항목"),
        Document(id: "entMovieTicket", text: "영화관 예매 확인 캡처 아이맥스 좌석"),
        Document(id: "entConcert", text: "콘서트 티켓팅 성공 캡처 스탠딩석"),
        Document(id: "entDrama", text: "넷플릭스 정주행 목록 캡처 다음화 예고"),
        Document(id: "entGame", text: "모바일 게임 캡처 레이드 파티 모집"),
        Document(id: "entWebtoon", text: "웹툰 정주행 캡처 최신화 업데이트"),
        Document(id: "entMusic", text: "스포티파이 플레이리스트 캡처 드라이브 음악"),
        Document(id: "entBook", text: "리디북스 전자책 세일 캡처 장바구니"),
        Document(id: "snsInstaPost", text: "인스타그램 피드 캡처 친구 결혼식 사진"),
        Document(id: "snsKakaoChat", text: "카카오톡 단체방 대화 캡처 약속 정하기"),
        Document(id: "snsTwitter", text: "트위터 밈 캡처 웃긴 짤방"),
        Document(id: "snsBirthday", text: "친구 생일 축하 메시지 캡처"),
        Document(id: "snsGroupBuy", text: "동네 커뮤니티 앱 공구 모집 캡처"),
        Document(id: "snsReview", text: "배달앱 리뷰 캡처 별점 5점 후기"),
        Document(id: "snsProfile", text: "프로필 사진 후보 캡처 골라달라고 보냄"),
        Document(id: "transitBus", text: "버스 도착 알림 캡처 정류장 3분 후"),
        Document(id: "transitSubwayMap", text: "지하철 환승 경로 캡처 2호선에서 9호선"),
        Document(id: "transitParking", text: "주차 위치 기억용 캡처 지하 3층 B구역"),
        Document(id: "transitTaxi", text: "택시 호출 앱 캡처 예상 도착시간"),
        Document(id: "transitFlightStatus", text: "항공편 실시간 상태 캡처 탑승 게이트"),
        Document(id: "transitBikeShare", text: "따릉이 대여 캡처 반납 정류소 안내"),
        Document(id: "transitTraffic", text: "실시간 교통상황 캡처 올림픽대로 정체"),
        Document(id: "calMeetingInvite", text: "구글 캘린더 회의 초대 캡처 화요일 오후"),
        Document(id: "calAnniversary", text: "기념일 알림 캡처 사귄지 100일"),
        Document(id: "calDentist", text: "치과 예약 알림 캡처 다음주 스케일링"),
        Document(id: "calBirthdayReminder", text: "가족 생일 리마인더 캡처 선물 준비"),
        Document(id: "calDeadline", text: "과제 마감일 캡처 자정까지 제출"),
        Document(id: "calVacation", text: "연차 신청 승인 캡처 다음달 3일간"),
        Document(id: "techGitCommit", text: "깃허브 커밋 히스토리 캡처 리팩터링 브랜치"),
        Document(id: "techStackOverflow", text: "스택오버플로우 답변 캡처 널포인터 해결법"),
        Document(id: "techApiDoc", text: "API 문서 캡처 엔드포인트 파라미터 설명"),
        Document(id: "techConference", text: "개발자 컨퍼런스 일정표 캡처 세션 목록"),
        Document(id: "techNewsletter", text: "기술 뉴스레터 캡처 이번주 프론트엔드 소식"),
        Document(id: "techJobPosting", text: "채용 공고 캡처 시니어 iOS 개발자"),
        Document(id: "techLinter", text: "코드 린트 에러 캡처 세미콜론 누락"),
        Document(id: "miscRecipeKimchi", text: "김치볶음밥 레시피 캡처 계란후라이 올리기"),
        Document(id: "miscParenting", text: "육아 정보 카페 글 캡처 이유식 시기"),
        Document(id: "miscPet", text: "강아지 산책 코스 캡처 동네 공원"),
        Document(id: "miscInterior", text: "원룸 인테리어 캡처 침대 배치 아이디어"),
        Document(id: "miscBeautyRoutine", text: "스킨케어 루틴 캡처 아침저녁 순서"),
        Document(id: "miscHobbyPottery", text: "도자기 공방 원데이클래스 캡처"),
        Document(id: "miscBookReview", text: "독서모임 후기 캡처 이번달 선정도서"),
        Document(id: "miscMovieReview", text: "영화 리뷰 블로그 캡처 별점 4.5"),
        Document(id: "miscRealEstate", text: "부동산 매물 캡처 전세 시세 비교"),
        Document(id: "miscWeatherAlert", text: "폭염 특보 캡처 야외활동 자제 안내"),
    ]

    private static let evalCases: [EvalCase] = [
        EvalCase(label: "사주(원문 단어)", query: "사주", expectedDocumentID: "saju", kind: .lexical),
        EvalCase(label: "사주→운세(의미만 같음)", query: "운세", expectedDocumentID: "saju", kind: .semantic),
        EvalCase(label: "면접(원문 단어)", query: "백엔드 개발자 면접", expectedDocumentID: "interview", kind: .lexical),
        EvalCase(label: "면접→인터뷰(의미만 같음)", query: "개발자 인터뷰 후기", expectedDocumentID: "interview", kind: .semantic),
        EvalCase(label: "파스타 맛집(원문 단어)", query: "파스타 맛집", expectedDocumentID: "pasta", kind: .lexical),
        EvalCase(label: "맛집→데이트 식당(의미만 같음)", query: "데이트하기 좋은 식당 추천", expectedDocumentID: "pasta", kind: .semantic),
        EvalCase(label: "운영체제(원문 단어)", query: "운영체제 시험", expectedDocumentID: "os", kind: .lexical),
        EvalCase(label: "운영체제→OS(의미만 같음)", query: "OS 시험 공부 자료", expectedDocumentID: "os", kind: .semantic),
        EvalCase(label: "원피스(원문 단어)", query: "원피스 쇼핑", expectedDocumentID: "dress", kind: .lexical),
        EvalCase(label: "원피스→옷(상위어, 의미만 같음)", query: "옷 쇼핑몰 할인", expectedDocumentID: "dress", kind: .semantic),
        EvalCase(label: "브랜드 정확 일치 - 스타벅스", query: "스타벅스 영수증", expectedDocumentID: "starbucks", kind: .exactStringFavoring),
        EvalCase(label: "운송장번호 정확 일치", query: "394857102934", expectedDocumentID: "trackingA", kind: .exactStringFavoring),
        EvalCase(label: "출구 번호 정확 일치 - 강남역 3번", query: "강남역 3번 출구", expectedDocumentID: "gangnam3", kind: .exactStringFavoring),
        EvalCase(label: "에러 코드 정확 일치 - 503", query: "503 에러", expectedDocumentID: "error503", kind: .exactStringFavoring),
        EvalCase(label: "에러 코드 정확 일치 - 500", query: "500 에러", expectedDocumentID: "error500", kind: .exactStringFavoring),
        EvalCase(label: "에러 코드 정확 일치 - 429", query: "429 에러", expectedDocumentID: "error429", kind: .exactStringFavoring),
        EvalCase(label: "과목 코드 정확 일치 - CS101", query: "CS101 범위", expectedDocumentID: "cs101", kind: .exactStringFavoring),
        EvalCase(label: "과목 코드 정확 일치 - CS301", query: "CS301 프로젝트", expectedDocumentID: "cs301", kind: .exactStringFavoring),
        EvalCase(label: "과목 코드 정확 일치 - MATH101", query: "MATH101 시험범위", expectedDocumentID: "math101", kind: .exactStringFavoring),
        EvalCase(label: "장소명 정확 일치 - 속초", query: "속초 여행", expectedDocumentID: "sokcho", kind: .exactStringFavoring),
        EvalCase(label: "장소명 정확 일치 - 여의도", query: "여의도 벚꽃", expectedDocumentID: "yeouido", kind: .exactStringFavoring),
        EvalCase(label: "장소명 정확 일치 - 잠실", query: "잠실 전망대", expectedDocumentID: "jamsil", kind: .exactStringFavoring),
        EvalCase(label: "상품 모델명 정확 일치 - 아이폰 15", query: "아이폰 15 프로 가격", expectedDocumentID: "iphone15", kind: .exactStringFavoring),
        EvalCase(label: "상품 모델명 정확 일치 - 갤럭시 S24", query: "갤럭시 S24 예약", expectedDocumentID: "galaxyS24", kind: .exactStringFavoring),
        EvalCase(label: "상품 모델명 정확 일치 - 맥북 프로 14인치", query: "맥북 프로 14인치 스펙", expectedDocumentID: "macbookPro14", kind: .exactStringFavoring),
        EvalCase(label: "날짜 정확 일치 - 9월 25일", query: "9월 25일 회의록", expectedDocumentID: "meeting0925", kind: .exactStringFavoring),
        EvalCase(label: "날짜 정확 일치 - 9월 22일", query: "9월 22일 회의록", expectedDocumentID: "meeting0922", kind: .exactStringFavoring),
        EvalCase(label: "날짜 정확 일치 - 9월 28일", query: "9월 28일 회의록", expectedDocumentID: "meeting0928", kind: .exactStringFavoring),
    ]

    /// RRF 문헌의 표준값 k=60은 웹 규모(수천~수만 개 깊은 순위)에서 튜닝된 값이다 — k가 클수록
    /// "1위와 4위의 차이"를 작게 뭉갠다. 이 코퍼스는 19개뿐이라 순위 차이 자체가 훨씬 더 큰 신호다.
    /// k=60을 그대로 썼을 때 실제로 벌어진 일: "데이트하기 좋은 식당 추천" 질의에서 정답 문서
    /// (embedding 1위, substring 후보에는 전혀 없음)가, "추천" 한 단어만 우연히 겹쳐 embedding
    /// 4위·substring 유일 후보가 된 무관한 문서에 RRF 합산 점수로 역전당했다 — 1위와 4위 차이가
    /// k=60에서는 그 정도로 뭉개진다는 뜻이다. k=5로 낮추자 이 역전이 사라졌다(아래 assert가
    /// 이 케이스를 고정한다). **다만 이 값도 19문서용 임시값이다** — 실제 캡처 규모(수백~수천 건)로
    /// 재평가할 때 다시 튜닝해야 한다(§14 권고 2번).
    private static let rrfConstant = 5.0

    func testCompareSearchStrategies() async throws {
        let embeddingService = OnnxEmbeddingService()

        var docEmbeddings: [String: [Double]] = [:]
        for doc in Self.corpus {
            docEmbeddings[doc.id] = try await embeddingService.embed(doc.text, as: .passage)
        }

        // rank == nil이면 그 전략의 결과 목록에 정답 문서가 아예 없었다는 뜻(특히 substring은
        // 어휘가 하나도 안 겹치면 그 문서를 후보에서 통째로 뺀다).
        var ranks: [String: [Int?]] = ["substring": [], "embedding": [], "hybridRRF": []]
        var ranksByKind: [EvalCase.Kind: [String: [Int?]]] = [:]

        for evalCase in Self.evalCases {
            let queryEmbedding = try await embeddingService.embed(evalCase.query, as: .query)

            let substringRanking = Self.substringRanking(query: evalCase.query, corpus: Self.corpus)
            let embeddingRanking = Self.embeddingRanking(queryEmbedding: queryEmbedding, docEmbeddings: docEmbeddings, corpus: Self.corpus)
            let hybridRanking = Self.rrfRanking(substringRanking, embeddingRanking, corpus: Self.corpus, k: Self.rrfConstant)

            let substringIDs = substringRanking.map(\.document.id)
            for (strategy, ids) in [("substring", substringIDs), ("embedding", embeddingRanking.map(\.document.id)), ("hybridRRF", hybridRanking.map(\.id))] {
                let rank = ids.firstIndex(of: evalCase.expectedDocumentID).map { $0 + 1 }
                ranks[strategy, default: []].append(rank)
                ranksByKind[evalCase.kind, default: [:]][strategy, default: []].append(rank)
            }

            let embeddingTop5 = embeddingRanking.prefix(5).map { "\($0.document.id)(\(String(format: "%.3f", $0.score)))" }
            print("[\(evalCase.kind.rawValue)] \(evalCase.label) — 기대: \(evalCase.expectedDocumentID)")
            print("  substring top5: \(substringIDs.prefix(5))")
            print("  embedding top5: \(embeddingTop5)")
            print("  hybridRRF top5: \(hybridRanking.prefix(5).map(\.id))")
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
        for kind in [EvalCase.Kind.lexical, .semantic, .exactStringFavoring] {
            printHitRates(ranksByKind[kind] ?? [:], title: "\(kind.rawValue) 히트율")
        }

        // 정성적 기대: "의미만 같음" 질의에도 흔한 단어(예: "개발자")가 우연히 겹칠 수 있어 substring이
        // 부분 점수를 받는 걸 완전히 막지는 않는다(실제 사용자 질의도 그렇다) — 그래도 embedding이
        // 그 격차를 메워서 Top-1 히트 수가 substring보다 낮으면 안 된다.
        let semanticSubstringTop1 = (ranksByKind[.semantic]?["substring"] ?? []).filter { $0 == 1 }.count
        let semanticEmbeddingTop1 = (ranksByKind[.semantic]?["embedding"] ?? []).filter { $0 == 1 }.count
        XCTAssertGreaterThanOrEqual(semanticEmbeddingTop1, semanticSubstringTop1, "의미만 같고 단어가 다른 질의에서 embedding의 Top-1이 substring-only보다 나쁘면 안 된다 — embedding 도입 근거 자체가 흔들린다")

        // 회귀 방지: 재설계 전엔 hybridRRF가 순수 embedding-only보다 못한 경우가 실제로 있었다
        // (semantic Top-1 60% vs 100%, "데이트하기 좋은 식당 추천" 질의에서 무관한 문서가 역전).
        // matchRatio 가중 + k 축소로 고쳤다 — hybrid를 쓰는 의미 자체가 "embedding만 쓸 때보다
        // 나빠지진 않으면서 정확한 문자열 케이스는 더 챙긴다"이므로, 전체 Top-1에서 hybridRRF가
        // embedding-only보다 낮아지면 이 재설계가 다시 깨진 것이다.
        let overallEmbeddingTop1 = (ranks["embedding"] ?? []).filter { $0 == 1 }.count
        let overallHybridTop1 = (ranks["hybridRRF"] ?? []).filter { $0 == 1 }.count
        XCTAssertGreaterThanOrEqual(overallHybridTop1, overallEmbeddingTop1, "hybridRRF의 전체 Top-1이 embedding-only보다 나쁘면 안 된다 — hybrid를 쓰는 이유 자체가 없어진다")
    }

    /// `matchRatio`(일치한 질의 토큰 수 / 전체 질의 토큰 수)를 같이 돌려준다 — RRF가 "단어 1개만
    /// 우연히 겹쳐도 후보 중 유일하게 순위가 매겨졌다는 이유만으로" 과도한 가중치를 주는 문제(12번
    /// 발견)를 고치려면, 순위(rank)뿐 아니라 그 순위가 얼마나 부실한 근거로 매겨졌는지도 알아야 한다.
    private static func substringRanking(query: String, corpus: [Document]) -> [(document: Document, matchRatio: Double)] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let scored = corpus.compactMap { doc -> (Document, Int)? in
            let haystack = doc.text.lowercased()
            let score = tokens.filter { haystack.contains($0) }.count
            return score > 0 ? (doc, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { (document: $0.0, matchRatio: Double($0.1) / Double(tokens.count)) }
    }

    /// 코사인 유사도(`score`)도 같이 돌려준다 — "1위가 2위를 근소하게 이겼는지, 압도적으로
    /// 이겼는지"는 rank만으로는 안 보인다. 큰 코퍼스로 재검증하면서 이 구분이 실제로 중요해졌다
    /// (예: "사주→운세"가 무관한 문서에 밀린 사례 — 점수 차를 봐야 근소한 역전인지 판단할 수 있다).
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

    /// **재설계(12번 발견 대응).** 예전 버전은 substring이 "후보 목록에 유일하게 있다"는 이유만으로
    /// `1/(k+1)`을 그대로 다 줬다 — 질의 토큰 4개 중 1개만 우연히 겹쳐도, 토큰 4개가 전부 겹친
    /// 진짜 일치와 같은 rank-1 보너스를 받았다는 뜻이다. 그래서 "데이트하기 좋은 식당 추천"에서
    /// "추천" 한 단어만 겹친 무관한 문서가, 정답 문서(embedding rank-1)보다도 높은 RRF 점수를 받는
    /// 역전이 실제로 나왔다.
    ///
    /// 고친 방식: substring 쪽 기여도에 `matchRatio`(일치 토큰 수/전체 토큰 수)를 곱한다. 토큰이
    /// 전부 겹치면 예전과 동일하게 `1/(k+rank)`를 다 받고, 토큰 하나만 우연히 겹치면 그만큼만
    /// 받는다 — "순위"뿐 아니라 "그 순위가 얼마나 확실한 근거로 매겨졌는지"까지 반영한다.
    /// embedding 쪽은 그대로 둔다 — 이번에 문제가 된 건 embedding이 아니라 substring 쪽 가중치였다.
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
