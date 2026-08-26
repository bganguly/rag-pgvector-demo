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

const NIM_MODEL = "nvidia/llama-3.1-nemotron-70b-instruct";
const NIM_DIAGNOSTIC_MODELS = [
  "meta/llama-3.1-8b-instruct",
  "meta/llama-3.1-70b-instruct",
];

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

async function nimPreflight(): Promise<void> {
  const key = process.env.NVIDIA_API_KEY ?? "";
  const keyInfo = key ? `len=${key.length} prefix=${key.slice(0, 8)}... suffix=...${key.slice(-6)}` : "(EMPTY — env var not set)";
  console.log(`[nim-preflight] NVIDIA_API_KEY: ${keyInfo}`);

  try {
    const modelsRes = await fetch("https://integrate.api.nvidia.com/v1/models", {
      headers: { Authorization: `Bearer ${key}` },
      signal: AbortSignal.timeout(6000),
    });
    const modelsBody = await modelsRes.text();
    console.log(`[nim-preflight] /v1/models status=${modelsRes.status}`);
    try {
      const parsed = JSON.parse(modelsBody);
      const ids = (parsed.data || []).map((m: {id: string}) => m.id).filter((id: string) => !id.includes("embed") && !id.includes("rerank"));
      console.log(`[nim-preflight] /v1/models chat-capable count=${ids.length}`);
      const hasNemotron = ids.includes(NIM_MODEL);
      console.log(`[nim-preflight] /v1/models has-nemotron=${hasNemotron}`);
      if (!hasNemotron) {
        console.warn(`[nim-preflight] WARNING: ${NIM_MODEL} not in catalog — key may lack access`);
        console.log(`[nim-preflight] /v1/models all-ids=${ids.join(", ")}`);
      }
    } catch {
      console.log(`[nim-preflight] /v1/models raw=${modelsBody.slice(0, 500)}`);
    }
  } catch (e) {
    console.error(`[nim-preflight] /v1/models fetch error=${e}`);
  }

  const allModels = [NIM_MODEL, ...NIM_DIAGNOSTIC_MODELS];
  for (const model of allModels) {
    const tag = model === NIM_MODEL ? "[primary]" : "[diagnostic-only]";
    try {
      console.log(`[nim-preflight] ${tag} testing model=${model}`);
      const chatRes = await fetch("https://integrate.api.nvidia.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${key}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          messages: [{ role: "user", content: "hi" }],
          max_tokens: 1,
          stream: false,
        }),
        signal: AbortSignal.timeout(12000),
      });
      const chatBody = await chatRes.text();
      console.log(`[nim-preflight] ${tag} model=${model} status=${chatRes.status}`);
      console.log(`[nim-preflight] ${tag} model=${model} body=${chatBody.slice(0, 600)}`);
    } catch (e) {
      console.error(`[nim-preflight] ${tag} model=${model} fetch error=${e}`);
    }
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

  if (provider === "nim") {
    console.log(`[chat] nim starting preflight, model=${NIM_MODEL}`);
    await nimPreflight();
  }

  const query = messages.at(-1)?.content ?? "";
  const backendUrl = process.env.BACKEND_URL ?? "http://localhost:8001";

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
        const msg = error instanceof Error ? error.message : String(error);
        logErr(`[chat/${provider}] stream-error`, error);
        return msg;
      },
    });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    logErr(`[chat/${provider}] sync-error`, e);
    return Response.json({ error: msg }, { status: 502 });
  }
}
