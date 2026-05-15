<?php
/**
 * IntraDocs — 사내 문서 열람 포털
 *
 * [취약 포인트]
 *  - ?page= 파라미터를 검증 없이 include() 에 전달
 *  - PHP iconv 확장이 활성화된 상태 (CVE-2024-2961 트리거 가능)
 *  - allow_url_include=On → php://filter wrapper 사용 가능
 */

$allowed = ['home', 'notice', 'contact'];
$page    = $_GET['page'] ?? 'home';

// ※ 취약 코드: 화이트리스트 우회 가능 (null byte, 경로 순회 등)
if (in_array($page, $allowed)) {
    $path = "pages/{$page}.php";
} else {
    // 관리자 편의용 직접 경로 지정 — 검증 없음!
    $path = $page;
}
?>
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <title>IntraDocs — 사내 문서 포털</title>
  <style>
    body { font-family: 'Segoe UI', sans-serif; margin: 0; background: #f4f6fa; color: #222; }
    header { background: #1a3c6e; color: #fff; padding: 14px 30px; display:flex; align-items:center; gap:12px; }
    header h1 { margin:0; font-size:1.3rem; }
    nav { background: #274e8a; padding: 8px 30px; }
    nav a { color: #cde; text-decoration: none; margin-right: 18px; font-size:.95rem; }
    nav a:hover { color: #fff; }
    main { max-width: 900px; margin: 30px auto; background: #fff;
           border-radius: 8px; padding: 30px; box-shadow: 0 2px 8px rgba(0,0,0,.1); }
    footer { text-align:center; color:#888; font-size:.8rem; padding:20px; }
  </style>
</head>
<body>
<header>
  <div>🏢</div>
  <h1>IntraDocs — 사내 문서 열람 시스템</h1>
</header>
<nav>
  <a href="?page=home">홈</a>
  <a href="?page=notice">공지사항</a>
  <a href="?page=contact">연락처</a>
  <a href="profile.php">⚙️ 환경 설정</a>
  <a href="api/xml-profile.php" style="color:#ffd">📡 XML API</a>
</nav>
<main>
<?php
// 취약한 include — LFI / php://filter 체인 공격 진입점
@include($path);
?>
</main>
<footer>IntraDocs v1.2 &copy; 2024 A회사</footer>
</body>
</html>
