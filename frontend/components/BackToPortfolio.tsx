'use client';

const PORTFOLIO_URL = 'https://bganguly.github.io/#rag_pgvector';

export default function BackToPortfolio() {
  function handleBack(e: React.MouseEvent<HTMLAnchorElement>) {
    e.preventDefault();
    try {
      if (window.opener && !window.opener.closed) {
        window.opener.location.href = PORTFOLIO_URL;
        window.close();
        return;
      }
    } catch (_) {}
    window.location.href = PORTFOLIO_URL;
  }

  return (
    <a
      href={PORTFOLIO_URL}
      onClick={handleBack}
      style={{ fontSize: 11, color: '#718096', textDecoration: 'none', display: 'block', marginBottom: 4, transition: 'color 0.15s' }}
      onMouseEnter={e => (e.currentTarget.style.color = '#a5b4fc')}
      onMouseLeave={e => (e.currentTarget.style.color = '#718096')}
    >
      ← Portfolio
    </a>
  );
}
