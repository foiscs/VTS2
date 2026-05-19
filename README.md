# VTS2 — 네트워크 보안 실습 랩

컨테이너 기반 네트워크 보안 실습 환경입니다.  
FRR 라우터, Suricata 인라인 IPS, DMZ/Intranet/DB 존 분리, 취약 웹앱(DVWA, Spring4Shell)으로 구성됩니다.

> **브랜치 안내**  
> `main` — ContainerLab 기반 배포  
> `docker-compose` — Docker Compose 기반 배포 (현재 문서 기준)

---

## 토폴로지

```
외부(10.0.1.100/veth-ext)
        │
   Router / FRR (10.0.1.1)
        │  eth2 (10.0.10.1)
        │
   veth-sur ──── sw-dmz (브리지)
        │              ├── DVWA        10.0.10.10   포트 80
   [Suricata IPS]      ├── PHP         10.0.10.30   포트 80
   NFQ 모드            ├── Juice Shop  10.0.10.40   포트 3000
   NFQUEUE on sw-dmz   ├── Spring      10.0.10.20   포트 8080
                       └── fw-int eth1 10.0.10.254
                                │ eth2 (10.0.20.1)
                          sw-intranet (브리지)
                                └── WAS / ProxySQL  10.0.20.10
                                │ eth3 (10.0.30.1)
                             sw-db (브리지)
                                └── MySQL           10.0.30.10
```

---

## 사전 요구사항

### Docker
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### ContainerLab (main 브랜치 사용 시)
```bash
bash -c "$(curl -sL https://get.containerlab.dev)"
```

### 저장소 클론
```bash
git clone https://github.com/foiscs/VTS2
cd VTS2
git checkout docker-compose   # Docker Compose 브랜치
```

---

## 배포 (Docker Compose 브랜치)

### 원커맨드 배포

```bash
sudo ./up.sh
```

내부적으로 아래 세 스크립트를 순서대로 실행합니다.

---

### 단계별 배포

#### 1단계 — 컨테이너 배포

```bash
sudo ./deploy-docker-compose.sh
```

수행 내용 (레이스 컨디션 방지 순서):

| Phase | 내용 |
|-------|------|
| 1 | 호스트 브리지 생성 (sw-dmz, sw-intranet, sw-db) |
| 2 | Docker 이미지 빌드 (DVWA, Spring — 없을 때만) |
| 3 | docker compose up -d |
| 4 | 컨테이너 PID 폴링 대기 (sleep 대신 실제 확인) |
| 5 | veth 페어 생성 + 브리지/netns 배선 |
| 6 | 컨테이너 IP / 추가 라우팅 설정 (nsenter) |
| 7 | fw-int iptables 정책 적용 |
| 8 | 호스트 라우팅 |

> 이미지 강제 재빌드: `sudo ./deploy-docker-compose.sh --rebuild`

#### 2단계 — Suricata IPS 시작

```bash
sudo ./start-suricata.sh
```

수행 내용:

| Phase | 내용 |
|-------|------|
| 0 | br_netfilter 로드 + sysctl 설정 |
| 8 | iptables NFQUEUE 룰 설정 (sw-dmz 기준, --queue-bypass 포함) |
| 9 | Suricata 컨테이너 시작 (NFQ IPS 모드, `-q 0`) |

#### 3단계 — 외부 접근 포트포워딩

```bash
sudo ./setup-port-forward.sh
```

완료 후 출력된 host IP로 접속:
- DVWA  → `http://<host-ip>:8001/`
- Spring → `http://<host-ip>:8002/main/login`

#### 4단계 — DVWA DB 초기화

브라우저에서 `http://10.0.10.10/setup.php` 접속 →  
**Create / Reset Database** 클릭 → `Setup successful` 확인

로그인: `admin` / `password`  
Security Level → **Low** 설정 후 실습

---

## 정리

```bash
sudo ./cleanup.sh
```

수행 내용: Suricata 제거 → docker compose down → iptables 룰 제거 → sysctl 초기화 → veth/브리지 제거

---

## 접속 정보

| 서비스 | 내부 주소 | 외부 포트 | 계정 |
|--------|-----------|-----------|------|
| DVWA | http://10.0.10.10/ | 8001 | admin / password |
| PHP Server | http://10.0.10.30/ | 8002 | — |
| Juice Shop | http://10.0.10.40:3000/ | 8003 | 회원가입 후 사용 |
| Spring | http://10.0.10.20:8080/main/login | 8004 | 회원가입 후 사용 |
| ProxySQL Admin | 10.0.20.10:6032 | — | admin / admin |
| MySQL | 10.0.30.10:3306 | — | dvwa / dvwapass |

---

## 보안 정책

### Suricata IPS (`configs/suricata/rules/local.rules`)

> 모드: NFQ IPS (iptables NFQUEUE → Suricata `-q 0`)  
> 탐지 인터페이스: sw-dmz 브리지 양방향

| SID | 분류 | 전송 방식 | 액션 |
|-----|------|-----------|------|
| 1000001 | SQLi UNION SELECT | GET (URI) | alert |
| 1000002 | SQLi OR 1=1 | GET (URI) | alert |
| 1000003 | SQLi 싱글쿼트+주석 | GET (URI) | alert |
| 1000004 | SQLi UNION SELECT — WAS | POST body | alert |
| 1000005 | SQLi UNION SELECT | POST body | alert |
| 1000006 | SQLi OR 1=1 | POST body | alert |
| 1000007 | SQLi 싱글쿼트+주석 | POST body | alert |
| 1001001–1001002 | XSS | GET (URI) | alert |
| 1002001–1002002 | Spring4Shell (CVE-2022-22965) | GET/POST | alert |
| 1003001 | PHP iconv RCE (CVE-2024-2961) | GET (URI) | alert |
| 1004001–1004002 | Path Traversal | GET (URI) | alert |
| 1005001 | DMZ→DB 직접 접근 | TCP | alert |
| 1006001 | 포트 스캔 탐지 | TCP SYN | alert |
| 1007001 | DMZ→External 비HTTP 아웃바운드 | TCP | alert |
| 1009001 | 외부→Intranet 직접 접근 | TCP | alert |
| 1009002 | 외부→DB 직접 접근 | TCP | alert |

### fw-int iptables (`DMZ ↔ Intranet 경계`)

FORWARD 기본 정책: **DROP**

| 출발 | 목적 | 프로토콜/포트 | 정책 |
|------|------|--------------|------|
| DVWA (10.0.10.10) | WAS (10.0.20.10) | TCP/3306 | ALLOW |
| Spring (10.0.10.20) | WAS (10.0.20.10) | TCP/3306 | ALLOW |
| WAS (10.0.20.10) | MySQL (10.0.30.10) | TCP/3306 | ALLOW |
| ANY | ANY | ANY | DROP |

---

## 탐지 검증

```bash
# 실시간 탐지 로그
tail -f /var/log/suricata/fast.log

# SQLi GET 테스트
curl -b /tmp/dvwa_cookie.txt \
  "http://10.0.10.10/vulnerabilities/sqli/?id=1+UNION+SELECT+1,2--+-&Submit=Submit"

# SQLi POST 테스트 (쿠키 먼저 획득)
curl -c /tmp/dvwa_cookie.txt \
  -d "username=admin&password=password&Login=Login" \
  -X POST "http://10.0.10.10/login.php"

# 외부→Intranet 직접 접근 탐지 확인
curl -m 3 http://10.0.20.10:8080 || true

# 외부→DB 직접 접근 탐지 확인
nc -zv 10.0.30.10 3306 -w 3 || true

# DMZ→DB 직접 접근 탐지 확인
docker exec dvwa nc -zv 10.0.30.10 3306 -w 3 || true

# 룰 리로드
docker exec suricata-ips suricatasc -c reload-rules

# IPS drop 룰 테스트
echo 'drop icmp any any -> any any (msg:"IPS DROP TEST"; sid:9999001; rev:1;)' \
  >> configs/suricata/rules/local.rules
docker exec suricata-ips suricatasc -c reload-rules
docker exec dvwa ping -c 3 10.0.1.100   # 차단되면 IPS 정상
sed -i '/sid:9999001/d' configs/suricata/rules/local.rules
docker exec suricata-ips suricatasc -c reload-rules
```

---

## 디렉토리 구조

```
VTS2/
├── up.sh                        # 원커맨드 배포 (deploy + suricata + portforward)
├── cleanup.sh                   # 전체 정리
├── deploy-docker-compose.sh     # 컨테이너/네트워크 배포
├── start-suricata.sh            # Suricata NFQ IPS 시작
├── setup-port-forward.sh        # 외부 접근 포트포워딩
├── docker-compose.yml           # 컨테이너 선언
├── configs/
│   ├── frr/
│   │   ├── router/              # FRR 라우터 설정
│   │   └── fw-int/              # FRR 방화벽 설정
│   ├── suricata/
│   │   ├── suricata.yaml        # Suricata 설정 (NFQ 모드)
│   │   └── rules/local.rules    # 탐지/차단 룰
│   └── proxysql/
│       └── proxysql.cnf         # ProxySQL 설정
└── DockerContainers/
    ├── DVWA/                    # DVWA 이미지 (vulnerables/web-dvwa:local)
    ├── PhpServer/               # PHP 취약 서버 (vts-php:latest, CVE-2024-2961)
    ├── SpringServer/            # Spring4Shell 취약 서버 (vts-spring:latest)
    └── mysql/
        └── init.sql             # DB 초기화
```

---

## VM 호스트 사양

| 항목 | 사양 |
|------|------|
| OS | Ubuntu |
| Memory | 4GB |
| Processors | 2 Core |
| Disk | 30GB |

## 컨테이너 리소스 사용량

| NAME | CPU % | MEM USAGE | MEM % |
|------|-------|-----------|-------|
| router/F/W | 0.05% | 7MB | 0.18% |
| suricata-ips | 0.5% | 14MB | 0.40% |
| dvwa | 0.01% | 18MB | 0.53% |
| spring | 0.3% | 300MB | 8.86% |
| fw-int | 0.05% | 5MB | 0.14% |
| was | 0.3% | 9MB | 0.26% |
| mysqlserver1 | 0.5% | 80MB | 2.39% |
| **TOTAL** | **1.71%** | **433MB** | **12.76%** |

## 이미지 디스크 사용량

| IMAGE | DISK USAGE | CONTENT SIZE |
|-------|------------|--------------|
| frrouting/frr:latest | 230MB | 70.3MB |
| jasonish/suricata:8.0.4-amd64 | 586MB | 141MB |
| mysql:8.0 | 1.1GB | 249MB |
| proxysql/proxysql:latest | 682MB | 176MB |
| vts-spring:latest | 1.16GB | 385MB |
| vulnerables/web-dvwa:local | 935MB | 178MB |
| **TOTAL (6 images)** | **4.69GB** | **1.20GB** |
