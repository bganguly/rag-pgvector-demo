import { streamText } from "ai";
import { anthropic } from "@ai-sdk/anthropic";
import { createOpenAI } from "@ai-sdk/openai";

const nim = createOpenAI({
  baseURL: "https://integrate.api.nvidia.com/v1",
  apiKey: process.env.NVIDIA_API_KEY ?? "",
});

const openai = createOpenAI({
  apiKey: process.env.OPENAI_API_KEY ?? "",
});

const NIM_MODEL = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning";

function pickModel(provider: string) {
  switch (provider) {
    case "nim":
      return nim(NIM_MODEL);
    case "openai":
      return openai("gpt-4o-mini");
    default:
      return anthropic("claude-haiku-4-5");
  }
}

function extractMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  const e = error as Record<string, unknown>;
  const candidate = e?.message ?? e?.detail ?? e?.title;
  if (typeof candidate === "string") return candidate;
  try { return JSON.stringify(e ?? error); } catch { return String(error); }
}

function logErr(tag: string, error: unknown) {
  const anyErr = error as Record<string, unknown>;
  console.error(`${tag} type=${error?.constructor?.name}`);
  console.error(`${tag} message=${anyErr?.message}`);
  console.error(`${tag} status=${anyErr?.status ?? anyErr?.statusCode}`);
  console.error(`${tag} url=${anyErr?.url}`);
  console.error(`${tag} responseBody=${anyErr?.responseBody}`);
  console.error(`${tag} data=${JSON.stringify(anyErr?.data)}`);
  console.error(`${tag} cause=${anyErr?.cause}`);
  try {
    console.error(`${tag} JSON=${JSON.stringify(error, Object.getOwnPropertyNames(error))}`);
  } catch {
    console.error(`${tag} JSON=(unstringifiable)`);
  }
}


export async function POST(req: Request) {
  const body = await req.json();
  const { messages, provider = "anthropic" } = body;

  console.log(`[chat] POST provider=${provider} messages=${messages?.length}`);

  if (provider === "nim" && !process.env.NVIDIA_API_KEY) {
    console.error("[chat] NVIDIA_API_KEY missing");
    return Response.json({ error: "NVIDIA_API_KEY is not configured on the server." }, { status: 502 });
  }

  const query = messages.at(-1)?.content ?? "";
  const backendUrl = (process.env.BACKEND_URL ?? "http://localhost:8001").replace(/\/$/, "");

  console.log(`[chat] query="${query.slice(0, 80)}" backendUrl=${backendUrl}`);

  let chunks: Array<{ content: string; source: string }> = [];
  let backendError = false;
  try {
    const retrieveRes = await fetch(`${backendUrl}/api/retrieve`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query, k: 5 }),
      signal: AbortSignal.timeout(8000),
    });
    console.log(`[chat] retrieve status=${retrieveRes.status}`);
    if (retrieveRes.ok) {
      const data = await retrieveRes.json();
      chunks = data.chunks ?? [];
      console.log(`[chat] retrieve chunks=${chunks.length}`);
    } else {
      backendError = true;
      console.warn(`[chat] retrieve non-ok status=${retrieveRes.status}`);
    }
  } catch (e) {
    backendError = true;
    console.warn(`[chat] retrieve error=${e}`);
  }

  const hasContext = !backendError && chunks.length > 0;
  console.log(`[chat] hasContext=${hasContext}`);

  const system = hasContext
    ? `You are a helpful assistant. Answer using only the context below.
If the context doesn't contain the answer, say so.
Cite source numbers like [1] when you use them.

Context:
${chunks.map((c, i) => `[${i + 1}] (source: ${c.source})\n${c.content}`).join("\n\n")}`
    : `You are a helpful assistant.
Begin your response with exactly this line: "**Generic LLM response** (not from loaded context)"
Then answer the question from your general knowledge.`;

  try {
    console.log(`[chat] calling streamText provider=${provider} model=${provider === "nim" ? NIM_MODEL : "default"}`);
    const result = streamText({
      model: pickModel(provider),
      system,
      messages,
    });
    console.log(`[chat] streamText returned, piping to response`);
    return result.toDataStreamResponse({
      getErrorMessage: (error) => {
        logErr(`[chat/${provider}] stream-error`, error);
        return extractMessage(error);
      },
    });
  } catch (e: unknown) {
    logErr(`[chat/${provider}] sync-error`, e);
    return Response.json({ error: extractMessage(e) }, { status: 502 });
  }
}
