"use client";

import { useState } from "react";
import ChatPanel from "@/components/ChatPanel";
import SeedPanel from "@/components/SeedPanel";
import UploadPanel from "@/components/UploadPanel";
import BackToPortfolio from "@/components/BackToPortfolio";

export type Provider = "anthropic" | "openai" | "nim";

const PROVIDER_LABELS: Record<Provider, { short: string; full: string }> = {
  anthropic: { short: "Claude", full: "Anthropic" },
  openai:    { short: "GPT",    full: "OpenAI" },
  nim:       { short: "NIM",    full: "NVIDIA NIM" },
};

function Toggle({ on, onToggle, label }: { on: boolean; onToggle: () => void; label: string }) {
  return (
    <label className="flex items-center gap-1.5 cursor-pointer select-none" title={label}>
      <button
        role="switch"
        aria-checked={on}
        onClick={onToggle}
        className="relative rounded-full shrink-0"
        style={{
          width: 28, height: 16,
          background: on ? "var(--accent)" : "var(--border)",
          transition: "background 0.15s",
          border: "none", padding: 0,
        }}
      >
        <span style={{
          position: "absolute", width: 12, height: 12, top: 2,
          left: on ? 14 : 2, background: "#fff", borderRadius: "50%",
          transition: "left 0.15s",
        }} />
      </button>
      <span className="hidden sm:inline text-[10px] font-mono uppercase tracking-wider" style={{ color: "var(--text-2)" }}>
        {label}
      </span>
    </label>
  );
}

export default function Home() {
  const [provider, setProvider] = useState<Provider>("anthropic");
  const [flushKB, setFlushKB]     = useState(false);
  const [flushChat, setFlushChat] = useState(false);
  const [ingested, setIngested]   = useState(false);
  const [tab, setTab]             = useState<"setup" | "chat">("setup");
  const [flushing, setFlushing]   = useState(false);
  const [seedResetKey, setSeedResetKey] = useState(0);
  const [chatClearKey, setChatClearKey] = useState(0);

  async function handleProviderSwitch(p: Provider) {
    if (p === provider) return;
    if (!flushKB && !flushChat) { setProvider(p); return; }
    setFlushing(true);
    try {
      if (flushKB) {
        await fetch("/api/reset", { method: "DELETE" }).catch(() => null);
        setIngested(false);
        setSeedResetKey((k) => k + 1);
      }
      if (flushChat) setChatClearKey((k) => k + 1);
    } finally {
      setProvider(p);
      setFlushing(false);
    }
  }

  return (
    <div className="flex flex-col h-screen">
      <header
        className="flex items-center justify-between px-4 sm:px-6 py-2 sm:py-3 border-b gap-2"
        style={{ background: "var(--surface)", borderColor: "var(--border)" }}
      >
        <div className="min-w-0">
          <BackToPortfolio />
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
              onClick={() => handleProviderSwitch(p)}
              disabled={flushing}
              className="px-2 sm:px-3 py-1 rounded text-[10px] sm:text-xs font-mono transition-colors"
              style={{
                background: provider === p ? "var(--accent)" : "var(--bg)",
                color: provider === p ? "#fff" : "var(--text-2)",
                border: `1px solid ${provider === p ? "var(--accent)" : "var(--border)"}`,
                opacity: flushing ? 0.5 : 1,
              }}
            >
              <span className="sm:hidden">{PROVIDER_LABELS[p].short}</span>
              <span className="hidden sm:inline">{PROVIDER_LABELS[p].full}</span>
            </button>
          ))}

          <div style={{ width: 1, height: 16, background: "var(--border)", margin: "0 2px" }} />

          <Toggle on={flushKB}   onToggle={() => setFlushKB((v) => !v)}   label="Flush KB" />
          <Toggle on={flushChat} onToggle={() => setFlushChat((v) => !v)} label="Flush chat" />
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

      <div className="flex flex-1 overflow-hidden relative">
        {flushing && (
          <div
            className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-3"
            style={{ background: "rgba(0,0,0,0.35)", backdropFilter: "blur(2px)" }}
          >
            <svg className="animate-spin" width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2.5">
              <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/>
            </svg>
            <span className="text-xs font-mono" style={{ color: "#fff" }}>
              {flushKB ? "Flushing knowledge base…" : "Clearing chat…"}
            </span>
          </div>
        )}
        <div
          className={`${tab === "setup" ? "flex" : "hidden"} sm:flex w-full sm:w-80 shrink-0 border-r overflow-y-auto flex-col`}
          style={{ background: "var(--surface)", borderColor: "var(--border)" }}
        >
          <SeedPanel onReady={() => { setIngested(true); setTab("chat"); }} resetKey={seedResetKey} />
          <div style={{ borderTop: "1px solid var(--border)" }} />
          <UploadPanel onIngest={() => { setIngested(true); setTab("chat"); }} />
        </div>
        <div className={`${tab === "chat" ? "flex" : "hidden"} sm:flex flex-1 overflow-hidden flex-col`}>
          <ChatPanel provider={provider} ingested={ingested} clearKey={chatClearKey} onPersistedDetected={() => setIngested(true)} />
        </div>
      </div>
    </div>
  );
}
