# PDFCraft 한국어 UI 수정 빌드

2026-10-22 / 원격 main 80b7d21525b263621818427b0223560101d1325f (Cargo 0.11.0) 기반의 로컬 수정판.

한국어는 기존 LANGUAGES와 날짜 언어 목록에 ko / 한국어로 등록한다. 시스템 언어 ko-KR·ko_KR.UTF-8을 따르는 자동 선택 및 환경 설정의 명시적 한국어 선택을 지원한다. 한국어 복수형은 단일 형태를 사용한다.

ko.tsv의 2,760개 항목은 이전 로컬 한국어판의 2,592개 문구를 그대로 유지하고, 원격 main의 추가 153개 번역과 최신 카탈로그 합집합에서 누락된 15개 번역을 통합했다. 모든 기존 번역 카탈로그의 영어 키를 포함하며, 명령·홈·도구·설정·대화상자·편집 기록·달력·접근성·서명 안내를 다룬다. 민감 정보 가리기(영구 삭제 적용), 평면화, 숨겨진 정보 제거를 서로 구분한다. 제품·표준·키캡 이름 및 숫자/파일명 자리표시자는 유지한다. 이전 source는 별도로 보존하며 통합 기록은 verification/pdfcraft-main-korean-20261022/catalog-merge-result.json에 있다.

한글 UI 글꼴은 별도 craft-fonts 입력의 NanumGothic Regular이며 OFL 1.1을 따른다. 고정 원본은 google/fonts commit 45e3d5269e4a17d823f6d84470bc084dc5ae46f6, ofl/nanumgothic/NanumGothic-Regular.ttf, SHA-256 76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31이다. 파일은 변경하지 않았으며, PDFCraft 저장소에 글꼴 파일을 복사하지 않는다. Windows 패키지에 OFL-nanum-gothic.txt와 FONT-INPUTS.json을 포함한다. 한국어 표시 검사는 PDFCRAFT_SYSTEM_FONTS=0으로 실시한다.

한국어 글꼴 입력을 구성하려면 위 고정 원본의 글꼴과 OFL.txt를 별도 입력의 fonts/nanum-gothic/에 두고, fonts/manifest.txt의 기존 항목을 유지하면서 다음 행을 추가한다. 패키징 단계가 글꼴 SHA-256과 OFL 파일을 확인한다.

```text
NanumGothic | Regular | fonts/nanum-gothic/NanumGothic-Regular.ttf | Hang,Latn | OFL-1.1 | fonts/nanum-gothic/OFL.txt | 76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31 | https://github.com/google/fonts/tree/45e3d5269e4a17d823f6d84470bc084dc5ae46f6/ofl/nanumgothic
```

일반 CI의 선택 craft-fonts 입력에 Hang 글꼴이 없으면 한국어 글리프 검사만 건너뛴다. 카탈로그·명령·자리표시자 검사는 계속 수행한다. PDFCRAFT_BUILD_LABEL이 ko.로 시작하는 한국어 빌드는 입력 자체가 없거나 Hang 글꼴이 빠져도 글리프 검사가 실패해야 하며, 글꼴이 있으면 네 가지 UI 글꼴 스타일에서 전체 한국어 문구를 확인한다.

한국어 UI는 사용자 PDF 본문·파일명·작성자·엔진/운영체제의 원시 오류 상세를 자동 번역하지 않는다. PDF 글꼴과 기존 본문 편집·OCR의 기능 범위는 해당 기능의 원래 제한을 따른다. 수정판에서 배포할 수 없는 upstream ArtCraft 로고와 이를 포함하는 문서 화면을 제외했다. 원작의 일반 텍스트 출처와 커뮤니티 링크는 유지한다.

검증: 카탈로그의 엄격한 파싱, 전체 UI literal/명령/기존 카탈로그 영어 키, 자리표시자·복수형·글리프, 한국어 날짜, Dev 실행, 배포 ZIP 추출 EXE, 언어 전환·재시작 유지·합성 PDF 저장, 실제 설치본과 ZIP/EXE 해시 readback을 각각 구분해 기록한다. 실제 결과는 배포 폴더의 DEPLOYMENT-RESULT.json과 공개 검증 자료에서 확인한다.

배포 절차와 복구는 [windows-korean-deployment.md](windows-korean-deployment.md)를 따른다. 현재 배포 범위는 현재 PC Windows 클라이언트와 로컬 배포 ZIP이다.

채우기 및 서명의 날짜를 PDF에 쓸 때에는 기존 엔진이 서유럽 문자만 허용한다. 한국어 월·요일 UI 표시와 달리 한글 날짜를 PDF에 쓰는 기능은 이번 범위에 추가하지 않았으며, 해당 경우 오류 안내에 따라 yyyy-mm-dd 같은 숫자 형식을 사용한다.

원격의 새 항목 중 영어로 남아 있던 47개 문구도 한국어로 보완했습니다. 기존 2,592개 번역은 모두 동일하게 유지합니다.
