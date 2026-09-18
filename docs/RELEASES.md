# 주요 릴리즈

개발 소스의 기준 브랜치는 `main`이다. 과거 버전은 아래 릴리즈·태그로 보존한다.

| 태그 | 단계 | 대표 QR 처리율 |
|---|---|---:|
| [qr-v0.1.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.1.0) | 원본 로컬 Runtime | 0.650/s |
| [qr-v0.2.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.2.0) | SW O2·연속 표시·조기 ACK | 0.978/s |
| [qr-v0.3.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.3.0) | PL+PS 프레임 정합성 | 4.879/s |
| [qr-v0.4.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.4.0) | Stage1 NEON·비차단 로그 | 4.884/s |
| [qr-v0.5.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.5.0) | Stage2 자율 PL 표시 | 4.885/s |
| [qr-v0.6.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.6.0) | Stage3 안정 15fps 입력 | 7.503/s |
| [qr-v0.7.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.7.0) | Stage4 선택 30fps 입력 | 15.006/s |
| [qr-v0.8.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.8.0) | PL 후보 주소 수정 | 15.006/s |
| [qr-v0.9.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.9.0) | Geometry/ROI·ECC 우선 | 15.006/s |
| [qr-v0.10.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.10.0) | QPP1 + seed8 | 30.004/s |
| [qr-v0.11.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.11.0) | 현재 Fast fallback | 30.012/s |

원본~Stage4는 9/17 일괄 측정이고 이후 버전은 각각 별도 검증이다. 전체 표를 동일 조건의 정확도 순위나 동일한 HDMI FPS 측정으로 해석하지 않는다. 처리율은 분석한 프레임 수/s이며 모든 카메라 입력을 반드시 처리했다는 의미가 아니다.

Stage1의 카메라 이동이 확인된 초기 중간 측정은 대표 값에서 제외했다. SW 개선 버전의 FRAME_STUCK 문제와 각 단계의 알려진 제한은 해당 릴리즈 설명에 보존했다.

각 Assets의 `<tag>.zip`에는 bit/XSA/ELF·소스 스냅샷·실행 스크립트·성능 집계·SHA-256 명세가 있다. GitHub가 자동 생성하는 Source code ZIP에는 실행 바이너리가 없다.

릴리즈 커밋은 보존 스냅샷을 사후 정리한 것으로, 과거 빌드 시점의 원래 커밋이나 깨끗한 환경에서의 재빌드 일치를 보장하지 않는다. [현재 버전 상세](CURRENT_VERSION.md)
