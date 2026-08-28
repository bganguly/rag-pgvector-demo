export async function DELETE() {
  const backendUrl = (process.env.BACKEND_URL ?? "http://localhost:8001").replace(/\/$/, "");
  const res = await fetch(`${backendUrl}/api/reset`, { method: "DELETE" });
  const data = await res.json();
  return Response.json(data, { status: res.status });
}
