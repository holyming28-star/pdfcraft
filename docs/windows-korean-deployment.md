# PDFCraft 한국어 Windows 클라이언트 배포

이 문서는 사용자 승인을 받은 한국어 수정판을 현재 PC의 독립된 폴더에 설치하고,
같은 폴더의 `updates/<release_id>`에 최종 ZIP과 검증 자료를 보관하는 절차다.
기본 설치 위치는 `D:\Codex\ArtCraft\PDFCraft`다. 서버/API/DB, NAS 또는 GitHub 게시,
자동 업데이트, 예약 작업, 파일 연결 등록, 원본 공식 패키지 교체는 이 절차에 포함하지 않는다.

## 빌드와 포터블 패키지

저장소 루트에서 PowerShell 7을 사용한다. `CRAFT_FONTS_DIR`은 한국어 NanumGothic과
그 OFL 파일을 포함한 별도 craft-fonts 입력을 가리켜야 한다. 글꼴 파일은 이 저장소에
복사하거나 커밋하지 않는다. 소스 테스트와 가능한 Dev 실행은 패키징 전에 별도로 수행한다.

```powershell
$env:CRAFT_FONTS_DIR = 'D:\Codex\ArtCraft\pdfcraft-fonts'
$env:PDFCRAFT_VERSION = '0.11.0-custom.20261022.korean.2'
$env:PDFCRAFT_BUILD_LABEL = 'ko.20261022.2'
$env:DIST = 'D:\Codex\ArtCraft\verification\pdfcraft-main-korean-20261022\package'
pwsh -NoProfile -File packaging/windows/package.ps1 -Arch x64 -PortableOnly
```

이미 검증된 동일 target의 release 실행 파일을 재사용할 때만 `-SkipBuild`를 추가한다.
`-PortableOnly`는 MSI/WiX 단계를 건너뛴다. 스위치를 생략하면 기존 MSI와 포터블 ZIP을
모두 만드는 동작을 유지한다. OCR 모델 획득과 해시 검증은 기존 `cargo xtask models`를 사용한다.
서명 설정이 없으면 기존 서명 스크립트가 경고한다. 이를 코드 서명된 배포로 보고하지 않는다.

패키징은 매번 `CARGO_TARGET_DIR/windows-package/work-<version>-<arch>-<random>`에
새 작업 폴더를 만들고 이전 작업 폴더를 재귀 삭제하지 않는다. 동일 이름의 기존 ZIP/MSI는
덮어쓰지 않으므로 재작업 시 새 `DIST` 또는 릴리스 ID를 선택한다. 출력의 `Portable payload:`가
이번 포터블 내용 디렉터리다. `ATTRIBUTION.md`, 프로젝트 라이선스/NOTICE, OCR 모델의 출처,
실제 포함 가능한 craft-fonts manifest 항목의 OFL을 함께 배포한다. Adobe 유래 금지 font family는
라이선스 수집에서도 제외한다. 한국어 릴리스에는 `OFL-nanum-gothic.txt`가 필요하다.
`PDFCRAFT_BUILD_LABEL`이 `ko.`로 시작하는 경우에도 한국어 필수 조건을 적용한다.
입력 글꼴의 실제 SHA-256을 manifest와 대조하고 `FONT-INPUTS.json`에 글꼴별 출처 경로,
SHA-256, 라이선스 및 글꼴 manifest 해시를 기록한다. 이 기록에는 개발 머신의 절대 경로를 넣지 않는다.
개발 프로필이나 제어 채널 token은 이 디렉터리에 추가하지 않는다.

## 최종 사용자 안내와 manifest

검증한 포터블 내용의 별도 최종 디렉터리에 `README-KOREAN.md`와
`release-manifest.json`을 추가한 뒤 최종 ZIP을 만든다. 초기 패키징 ZIP은 준비 자료이며,
설치 프로그램에 넘기는 최종 ZIP에는 이 두 파일이 모두 들어 있어야 한다.
manifest의 모든 `path`는 내용 디렉터리 기준 상대 경로다. 대소문자를 구분하지 않고
중복을 거부한다. `release-manifest.json` 자신을 제외한 **모든 파일**을 나열한다.

```json
{
  "schema_version": 1,
  "release_id": "0.11.0-custom.20261022.korean.2",
  "version": "0.11.0-custom.20261022.korean.2",
  "files": [
    { "path": "pdfcraft.exe", "length": 12345, "sha256": "64자리 SHA-256" },
    { "path": "models/ATTRIBUTION.txt", "length": 123, "sha256": "64자리 SHA-256" }
  ]
}
```

위 목록은 구조 예시다. 실제 EXE 크기/해시를 사용하고 모든 파일을 포함한다.
필수 파일은 `pdfcraft.exe`, `pdfcraft-cli.exe`, `portable.txt`, `ATTRIBUTION.md`,
`NOTICE`, `LICENSE-MIT`, `LICENSE-APACHE`, `OFL-nanum-gothic.txt`, `README-KOREAN.md`다.
README에는 릴리스 ID와 범위/위치, 보이는 변경 사항, 설치/업데이트 단계,
검증 수준과 시각, 설정·원본·이전 릴리스 보존, 롤백 방법 및 남은 한계를 기록한다.
ZIP 자신의 SHA-256은 자기 참조를 피하도록 외부 `.sha256` 파일과 최종 사용자 보고에 기록한다.

최종 디렉터리와 최종 ZIP은 내용이 같아야 한다. ZIP은 내용이 루트에 있거나 하나의
최상위 폴더 안에 있어도 된다. 설치기는 ZIP 전체 해시를 입력한 기대 해시와 먼저 비교한 뒤,
ZIP 내부 각 파일과 추출된 디렉터리의 각 파일을 manifest의 크기·SHA-256으로 다시 확인한다.
경로 이탈, 중복 ZIP 항목, 링크, 빠진 파일, 예상 밖의 파일, 프로필/인증서/제어 token 파일은
설치를 막는다. 설치기는 ZIP을 임의의 경로에 풀지 않고 검증된 추출 디렉터리의 파일만 개별 복사한다.

## 실제 설치와 로컬 발행

모든 PDFCraft 창에서 작업을 저장하고 정상 종료한다. 스크립트는 PC 전체의 `pdfcraft`
프로세스가 하나라도 남으면 중단하며 강제 종료하지 않는다. ZIP 검증만으로 설치나 활성화가
완료되었다고 보고하지 않는다.

```powershell
pwsh -NoProfile -File packaging/windows/install-local.ps1 `
  -PackageDirectory 'D:\검증된-최종-내용-디렉터리' `
  -PackageZip 'D:\검증된-최종-PDFCraft-한국어.zip' `
  -ExpectedZipSha256 '실제_64자리_SHA256' `
  -ReleaseId '0.11.0-custom.20261022.korean.2' `
  -PublicEvidenceDirectory 'D:\공개검증자료' `
  -PublicEvidenceFiles 'catalog-validation.json', 'installed-korean-ui.png'
```

`-InstallRoot`를 생략하면 기본 고정 폴더를 사용한다. 보호된 원본 패키지 트리와
동일하거나 상하위 관계인 설치 폴더는 거부한다. 최초 설정 이전이 필요할 때만
`-OriginalProfileDirectory`에 **실제로 확인한** 원본 `ARTCRAFT-Windows/.../PdfCraftData`를
지정한다. 다른 원본 패키지 위치를 명시적으로 사용할 때는 `-OriginalPackageRoot`도 지정한다.
원본 프로필은 설치 시점에만 읽어 비공개 백업하고, 새 `profile`이 존재하지 않을 때만 복사한다.
기존 `profile`에는 병합하거나 덮어쓰지 않는다. 프로필 경로와 내부의 링크/재분석 지점은 거부한다.

설치기는 다음 구조를 사용한다.

```text
PDFCraft/
  Run-PDFCraft.cmd             안정된 실행 진입점
  Run-PDFCraft.ps1             current.json을 읽는 실행 도우미
  current.json                원자적으로 교체되는 활성 버전 포인터
  profile/                    버전과 독립된 개인 설정·복구·디지털 ID
  releases/<release_id>/       검증된 버전별 배포 내용
    PdfCraftData -> ../../profile  Windows 디렉터리 junction
  updates/<release_id>/        최종 ZIP, .sha256, README, manifest, 허용한 공개 증거
  backups/<UTC시각-난수>/      이전 포인터·실행기·바로가기·프로필과 설치 영수증
```

`.install.lock`을 배타적으로 열어 중복 설치를 막는다. 기존 버전이나 게시 파일이
같은 해시이면 재사용하고 다른 내용이면 보존한 채 중단한다. 새 버전은 별도 staging에
검증 복사한 뒤 옮긴다. 설정은 각 릴리스의 `PdfCraftData` junction을 통해 같은 `profile`을 쓴다.
백업 폴더와 새 개인 프로필의 권한은 현재 사용자·SYSTEM·Administrators로 제한한다.
기존 프로필의 권한은 변경하지 않는다. 백업에는 개인 디지털 ID가 포함될 수 있으므로
공개 증거로 복사하거나 전송하지 않는다.

현재 사용자 바탕 화면과 시작 메뉴에 `PDFCraft (한국어)` 바로가기를 만든다. 같은 이름의
바로가기가 다른 대상을 가리키면 덮어쓰지 않는다. 실행기와 포인터는 같은 디렉터리의
임시 파일에서 원자적으로 교체한다. 활성 `current.json` 교체가 마지막 작업이다.
기존 공식 포터블 원본과 다른 앱의 실행기/바로가기/설정에는 쓰지 않는다.
격리된 설치 검증에서만 `-NoShortcuts`를 사용하면 바탕 화면과 시작 메뉴에 쓰지 않는다.
이 경우에도 지정한 설치 폴더의 프로필·실행기·포인터·발행 자료는 실제로 생성되므로,
실제 배포 명령 대신 실행하는 읽기 전용 검사는 아니다.

공개 증거는 호출자가 명시한 파일명만 복사한다. 하위 폴더 재귀 수집은 하지 않으며
JSON/PNG/TXT/MD만 받는다. 내용을 사전에 검토하여 업무 원본·최근 파일명·인증 정보·
control 연결 파일·token이 없는 결과만 선택한다. 증거 목록을 생략한 경우 발행 자료는
최종 ZIP/해시/README/manifest뿐이다. 설치 후 UI 검증 자료를 추가할 때도 검토한 파일만
명시적으로 복사하고 그 해시를 읽어 확인한다. 설치 중 만들어진 비공개 영수증을 그대로
공개 자료로 쓰지 않는다.

## 설치 후 확인과 롤백

`current.json`과 설치된 manifest/EXE 및 `updates`의 ZIP을 다시 읽어 기대 해시와 비교한다.
`Run-PDFCraft.cmd` 또는 새 바로가기로 실행하고 프로세스의 실제 EXE 경로, 유효한 창 핸들,
제목/응답성과 한국어 메뉴·환경 설정·대화상자를 확인한다. 합성 PDF로 열기/저장과
언어 유지 상태를 확인하고, 필요한 경우 정상 종료·재실행하여 설정 보존을 확인한다.
설치 스크립트의 성공은 파일 검증과 로컬 활성 포인터까지만 증명한다. 실제 창, 업무 파일,
다른 물리 PC, 코드 서명, MSI 설치 검증은 각각 수행한 수준으로 구분하여 보고한다.

롤백도 작업을 저장하고 모든 PDFCraft를 정상 종료한 뒤 수행한다. 이전 릴리스 내용과
`backups/<시각>/current.json`을 확인하고 포인터를 같은 디렉터리의 임시 파일을 거쳐
원자적으로 복원한다. 새 릴리스와 ZIP은 삭제할 필요가 없다. 실행기를 바꾼 경우 같은 백업의
`Run-PDFCraft.cmd`, `Run-PDFCraft.ps1`과 바로가기 백업도 확인하여 복원한다. 개인 프로필은
공유 상태를 계속 사용하며, 이전 프로필 복원이 필요한 경우 현재 프로필부터 별도로 보존한 후
명시적으로 복구한다. 프로필이나 디지털 ID를 무조건 옛 백업으로 덮어쓰지 않는다.

진행 중 실패하면 기존 활성 포인터는 마지막 원자 교체 전 상태로 남는다. 새 staging/릴리스와
부분 게시 파일, 비공개 백업은 조사용으로 남기며 재귀 삭제하지 않는다. 최초 설치에서 포인터
생성 전 실행기 생성에 실패한 경우 백업과 오류를 확인하고 새 실행기를 보존한 별도 이름으로
옮긴 다음 재시도한다. 오류를 무시하거나 기존 파일에 강제 덮어쓰기하지 않는다.
