export async function POST(req: Request) {
  const formData = await req.formData();
  const backendUrl = (process.env.BACKEND_URL ?? "http://localhost:8001").replace(/\/$/, "");
  const target = `${backendUrl}/api/ingest`;

  console.log("[ingest] received POST, BACKEND_URL =", process.env.BACKEND_URL ?? "(unset)", "-> target:", target);

  try {
    const res = await fetch(target, {
      method: "POST",
      body: formData,
      signal: AbortSignal.timeout(90000),
    });
    console.log("[ingest] backend responded:", res.status);
    let data: unknown;
    const text = await res.text();
    try { data = JSON.parse(text); } catch { data = { detail: text }; }
    console.log("[ingest] backend body:", text.slice(0, 300));
    return Response.json(data, { status: res.status });
  } catch (err) {
    console.error("[ingest] fetch threw:", err);
    return Response.json({ detail: "Backend unavailable" }, { status: 503 });
  }
}
