"use client";

import { useState } from "react";
import ChatPanel from "@/components/ChatPanel";
import SeedPanel from "@/components/SeedPanel";
import UploadPanel from "@/components/UploadPanel";

export type Provider = "anthropic" | "openai" | "nim";

const PROVIDER_LABELS: Record<Provider, { short: string; full: string }> = {
  anthropic: { short: "Claude", full: "Anthropic" },
  openai:    { short: "GPT",    full: "OpenAI" },
  nim:       { short: "NIM",    full: "NVIDIA NIM" },
};

export default function Home() {
  const [provider, setProvider] = useState<Provider>("anthropic");
  const [ingested, setIngested] = useState(false);
  const [tab, setTab] = useState<"setup" | "chat">("setup");

  return (
    <div className="flex flex-col h-screen">
      <header
        className="flex items-center justify-between px-4 sm:px-6 py-2 sm:py-3 border-b gap-2"
        style={{ background: "var(--surface)", borderColor: "var(--border)" }}
      >
        <div className="min-w-0">
          <span
            className="text-xs font-mono tracking-widest uppercase"
            style={{ color: "var(--accent)" }}
          >
            RAG Demo
          </span>
          <h1 className="text-sm sm:text-base font-semibold" style={{ color: "var(--text)" }}>
            <span className="hidden sm:inline">pgvector · LangChain · Vercel AI SDK</span>
            <span className="sm:hidden">pgvector · LangChain</span>
          </h1>
        </div>

        <div className="flex items-center gap-1 sm:gap-2 shrink-0">
          <span
            className="hidden sm:inline text-xs font-mono uppercase tracking-wider"
            style={{ color: "var(--text-2)" }}
          >
            Provider
          </span>
          {(["anthropic", "openai", "nim"] as Provider[]).map((p) => (
            <button
              key={p}
              onClick={() => setProvider(p)}
              className="px-2 sm:px-3 py-1 rounded text-[10px] sm:text-xs font-mono transition-colors"
              style={{
                background: provider === p ? "var(--accent)" : "var(--bg)",
                color: provider === p ? "#fff" : "var(--text-2)",
                border: `1px solid ${provider === p ? "var(--accent)" : "var(--border)"}`,
              }}
            >
              <span className="sm:hidden">{PROVIDER_LABELS[p].short}</span>
              <span className="hidden sm:inline">{PROVIDER_LABELS[p].full}</span>
            </button>
          ))}
        </div>
      </header>

      <div
        className="flex sm:hidden border-b"
        style={{ borderColor: "var(--border)", background: "var(--surface)" }}
      >
        {(["setup", "chat"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className="flex-1 py-2 text-xs font-mono uppercase tracking-wider transition-colors"
            style={{
              color: tab === t ? "var(--accent)" : "var(--text-2)",
              borderBottom: tab === t ? "2px solid var(--accent)" : "2px solid transparent",
            }}
          >
            {t === "setup" ? "Knowledge Base" : "Chat"}
          </button>
        ))}
      </div>

      <div className="flex flex-1 overflow-hidden">
        <div
          className={`${tab === "setup" ? "flex" : "hidden"} sm:flex w-full sm:w-80 shrink-0 border-r overflow-y-auto flex-col`}
          style={{ background: "var(--surface)", borderColor: "var(--border)" }}
        >
          <SeedPanel onReady={() => { setIngested(true); setTab("chat"); }} />
          <div style={{ borderTop: "1px solid var(--border)" }} />
          <UploadPanel onIngest={() => { setIngested(true); setTab("chat"); }} />
        </div>
        <div className={`${tab === "chat" ? "flex" : "hidden"} sm:flex flex-1 overflow-hidden flex-col`}>
          <ChatPanel provider={provider} ingested={ingested} />
        </div>
      </div>
    </div>
  );
}
