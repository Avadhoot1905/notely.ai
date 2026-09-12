# Notely.ai

> An open-source, local-first meeting intelligence engine that turns multilingual conversations into structured, evidence-backed Minutes of Meeting (MOM) — without sending your meetings to the cloud.

**Status: Early concept / architecture exploration**

---

## The Idea

Most AI meeting assistants follow roughly the same model:

```text
Meeting
   ↓
Cloud transcription
   ↓
Cloud LLM
   ↓
AI-generated notes
```

They work, but they introduce recurring problems:

- Privacy concerns
- Cloud/API costs
- Subscription models
- Vendor lock-in
- Limited control over models
- Poor support for local or mixed-language conversations
- Little visibility into where an AI-generated claim came from

This project explores a different approach:

```text
Meeting
   ↓
Local processing
   ↓
Local speech recognition
   ↓
Local LLM
   ↓
Structured meeting intelligence
   ↓
Evidence-backed MOM
```

Everything can run locally.

No mandatory cloud service.  
No API key.  
No subscription.

---

# Goals

### Primary goals

- Fully local meeting processing
- Open source
- Multilingual and code-switched meeting support
- High-quality MOM generation
- Structured extraction of decisions and action items
- Evidence/provenance for generated information
- Model-agnostic architecture
- Minimal resource requirements where practical
- CLI-first, with a GUI as an optional layer

### Non-goals for the initial version

We are **not** trying to immediately build:

- A Zoom/Teams competitor
- A SaaS platform
- A collaborative workspace
- Enterprise RBAC
- Calendar/task integrations
- A massive knowledge graph
- A complicated multi-agent framework

The first question is much simpler:

> **Can we turn a meeting recording into a genuinely useful MOM locally?**

---

# Core Philosophy

## 1. Local-first

Meeting audio can contain extremely sensitive information.

The default architecture should therefore be:

```text
┌─────────────────────────────────────────┐
│             User's Machine              │
│                                         │
│  Audio → ASR → LLM → MOM                │
│                                         │
└─────────────────────────────────────────┘
```

Cloud providers may eventually be supported as optional adapters, but they should never be required.

---

## 2. Multiple processing stages ≠ multiple AI models

The system may perform several reasoning stages without requiring several different LLMs.

For example:

```text
Transcript
    ↓
Analysis
    ↓
Meeting IR
    ↓
Verification
    ↓
MOM generation
```

The same local model can perform each stage:

```text
                  Qwen / Gemma
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
       Analyst       Critic       Writer
```

This keeps the system lightweight while still allowing specialized prompts and processing stages.

---

## 3. Use traditional software wherever possible

Not every problem needs an LLM.

```text
Audio segmentation       → deterministic / VAD
Timestamp management     → deterministic
Speaker segment merging  → deterministic
Transcript storage       → deterministic
JSON validation          → deterministic
MOM rendering            → templates
Semantic extraction      → LLM
Reasoning                → LLM
Verification             → LLM
```

The LLM should be used where language understanding is actually required.

---

# Proposed Architecture

```text
                         ┌──────────────────┐
                         │    MOM Engine    │
                         └────────┬─────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
                 Audio                       Transcript
                    │                           │
                    ▼                           │
                   VAD                          │
                    │                           │
                    ▼                           │
                   ASR                          │
             Qwen3-ASR / Whisper                │
                    │                           │
                    ▼                           │
             Speaker Diarization                │
                    │                           │
                    └─────────────┬─────────────┘
                                  ▼
                        Canonical Transcript
                                  │
                                  ▼
                       ┌──────────────────┐
                       │  Meeting Brain   │
                       │                  │
                       │  Qwen / Gemma    │
                       └────────┬─────────┘
                                │
                                ▼
                          Meeting IR
                                │
             ┌──────────────────┼──────────────────┐
             │                  │                  │
             ▼                  ▼                  ▼
         Decisions         Action Items        Topics
             │                  │                  │
             └──────────────────┼──────────────────┘
                                ▼
                         Verification
                                │
                                ▼
                         MOM Renderer
                                │
                  ┌─────────────┼─────────────┐
                  ▼             ▼             ▼
                Markdown       JSON          PDF
```

---

# Meeting IR

The **Meeting IR (Intermediate Representation)** is intended to be the central abstraction of the system.

The LLM should not directly generate the final MOM whenever possible.

Instead:

```text
Transcript
    ↓
Meeting IR
    ↓
MOM
```

A rough representation:

```json
{
  "metadata": {
    "title": "Product Planning",
    "date": "2026-09-12"
  },

  "participants": [],

  "topics": [],

  "decisions": [],

  "action_items": [],

  "questions": [],

  "risks": [],

  "timeline": []
}
```

The exact schema is intentionally undecided.

The IR should become the stable contract between the reasoning layer and everything that consumes meeting intelligence.

---

# Evidence / Provenance

A major design goal is to make generated information traceable back to the meeting.

For example:

```json
{
  "task": "Complete database migration",
  "owner": "Avadhoot",
  "deadline": "Friday",

  "evidence": {
    "start": 2612.4,
    "end": 2621.7
  }
}
```

The UI could therefore show:

```text
Action Items

☐ Avadhoot
  Complete database migration
  Deadline: Friday

  [View source →]
```

which jumps directly to the relevant transcript segment.

This provides a mechanism for users to verify AI-generated claims instead of blindly trusting the model.

---

# Multilingual Meetings

Multilingual support should be a first-class capability.

Meetings may contain:

```text
English
Hindi
Marathi
Hinglish
Code-switching
Technical terminology
Names and acronyms
```

The system should **not necessarily translate everything into English before reasoning**.

Instead:

```text
Hindi + English + Marathi + technical terms
                    ↓
             Multilingual ASR
                    ↓
          Multilingual transcript
                    ↓
             Qwen / Gemma
                    ↓
            Meeting intelligence
```

The final MOM can optionally be generated in:

- English
- Original language
- Another requested language
- Bilingual format

---

# Model Strategy

The application should remain model-agnostic.

Potential local models include:

### Reasoning / summarization

- Qwen3
- Gemma 3
- Future Qwen/Gemma releases
- Other Ollama-compatible models

### Speech recognition

- Qwen3-ASR
- Whisper
- Whisper.cpp
- Other local ASR implementations

The application should not hard-code assumptions about a particular model.

---

# Ollama

Ollama is an initial target for local LLM execution because it provides a simple interface for running models locally.

Conceptually:

```text
MOM Engine
     │
     ▼
LLM Provider
     │
     ▼
Ollama
     │
 ┌───┴────┐
 ▼        ▼
Qwen     Gemma
```

However, the provider abstraction should allow future support for:

- Ollama
- LM Studio
- llama.cpp
- OpenAI-compatible local servers
- Cloud APIs (optional)

The model and the provider should be separate concepts.

---

# Provider Abstraction

A rough interface:

```typescript
interface LLMProvider {
  generate(request: LLMRequest): Promise<LLMResponse>;
}
```

Possible implementations:

```text
OllamaProvider
OpenAICompatibleProvider
LMStudioProvider
```

Likewise, transcription should be abstracted:

```typescript
interface Transcriber {
  transcribe(audio: AudioInput): Promise<Transcript>;
}
```

This allows the engine to evolve without coupling itself to one model ecosystem.

---

# Processing Modes

The system could eventually expose different quality/speed modes.

### Fast

```text
Audio
 ↓
ASR
 ↓
LLM
 ↓
Meeting IR
 ↓
MOM
```

### Verified

```text
Audio
 ↓
ASR
 ↓
LLM
 ↓
Meeting IR
 ↓
LLM verification
 ↓
MOM
```

The same model can be used for both reasoning stages.

This makes verification an optional quality/cost tradeoff rather than a mandatory architectural burden.

---

# Input Sources

The core engine should not depend on a particular recording application.

Possible inputs:

```bash
mom process meeting.wav
mom process meeting.mp3
mom process transcript.json
```

Eventually:

```bash
mom live
```

could support live microphone/system-audio processing.

This separation means recordings from other applications can be processed as well.

Potential sources include:

- Zoom recordings
- Teams recordings
- Google Meet recordings
- OBS
- Phone recordings
- Existing audio files
- Live microphone/system audio

---

# Output

The same Meeting IR can power multiple outputs.

```text
                    Meeting IR
                        │
        ┌───────────────┼────────────────┐
        ▼               ▼                ▼
      MOM.md          JSON             PDF
        │
        ├── Summary
        ├── Decisions
        ├── Action Items
        ├── Participants
        ├── Topics
        ├── Questions
        └── Risks
```

Future integrations could consume the same structured representation:

```text
Meeting IR
   ├──→ Jira issues
   ├──→ Calendar events
   ├──→ Slack summary
   ├──→ Notion page
   └──→ Project knowledge base
```

These are **future consumers**, not MVP requirements.

---

# Storage Philosophy

The initial implementation should favor simple, inspectable files.

A meeting could look like:

```text
meetings/
└── 2026-09-12-product-planning/
    ├── audio.wav
    ├── transcript.json
    ├── meeting.json
    └── mom.md
```

A database can be introduced later if search, indexing, synchronization, or multi-user workflows require it.

The filesystem should remain a viable storage backend.

---

# CLI

The first interface should be simple.

```bash
mom run meeting.wav
```

Output:

```text
✓ Transcribed
✓ Analyzed
✓ Generated MOM

Meeting:
  Product Planning

Duration:
  52m 13s

Output:
  meetings/2026-09-12-product-planning/mom.md
```

Verification:

```bash
mom run meeting.wav --verify
```

Model selection:

```bash
mom run meeting.wav --model qwen3
```

Eventually:

```bash
mom run meeting.wav --model gemma3
```

---

# Potential Desktop UI

A desktop application can eventually sit on top of the engine.

Possible stack:

```text
Tauri
   +
React
   +
MOM Engine
```

The UI should not contain the core meeting-processing logic.

Instead:

```text
                 Desktop UI
                     │
                     ▼
                MOM Engine
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
       ASR          LLM         Storage
```

This allows the CLI, desktop application, and future API to share the same engine.

---

# Existing Projects to Learn From

This project is inspired by and should learn from existing open-source meeting tools rather than reinventing their solutions blindly.

### Meetily

Full local meeting assistant with desktop capture, local transcription, diarization, Ollama integration, and hardware acceleration.

**Lesson:** solve local desktop capture and cross-platform issues properly.

### Mityu

Local-first meeting intelligence with an emphasis on structured summaries, source-linked information, human verification, and future agents.

**Lesson:** AI output should be traceable and verifiable.

### Hyprnote

Meeting notes combine transcription with human-written context.

**Lesson:** human notes are valuable context and should not be replaced blindly by AI.

### clawd-scribe

Extremely small local meeting recorder using local transcription and Ollama.

**Lesson:** a useful local meeting assistant does not need a giant software stack.

### Sard

Local transcription + multiple local LLM providers.

**Lesson:** separate models, providers, and application logic.

### Murmur

CLI-oriented meeting transcription and note generation.

**Lesson:** the simplest useful interface can be a single command.

### Squirrel Notes

Minimal Whisper → Ollama → Markdown workflow.

**Lesson:** don't over-engineer the first version.

---

# What Could Make This Different?

The goal is **not** to beat existing projects by having more features.

The project should instead focus on:

### 1. Small core

A developer should be able to understand the entire processing pipeline.

### 2. Model agnosticism

Qwen, Gemma, Whisper, Ollama, llama.cpp, etc. should be replaceable.

### 3. Structured meeting intelligence

The Meeting IR should be more important than the final Markdown document.

### 4. Evidence-backed output

Every important decision/action should ideally be traceable to the transcript.

### 5. Multilingual reasoning

Mixed-language conversations should be treated as normal rather than as an edge case.

### 6. Local-first privacy

The default should be that meeting data stays on the user's machine.

### 7. Composability

The engine should eventually be usable as:

```text
CLI
API
Library
Desktop application
```

---

# Rough Roadmap

## Phase 0 — Architecture

- [ ] Define Meeting IR
- [ ] Define Transcript schema
- [ ] Define LLM provider interface
- [ ] Define transcription interface
- [ ] Decide initial storage format
- [ ] Establish evaluation dataset

## Phase 1 — Minimal Pipeline

```text
audio
 ↓
ASR
 ↓
LLM
 ↓
Meeting IR
 ↓
Markdown MOM
```

- [ ] Audio input
- [ ] Local ASR
- [ ] Ollama integration
- [ ] Qwen/Gemma support
- [ ] Structured extraction
- [ ] MOM renderer
- [ ] CLI

## Phase 2 — Better Meeting Intelligence

- [ ] Speaker diarization
- [ ] Action item extraction
- [ ] Decision extraction
- [ ] Topic segmentation
- [ ] Questions
- [ ] Risks
- [ ] Meeting timeline

## Phase 3 — Reliability

- [ ] Evidence/provenance
- [ ] Source timestamps
- [ ] Verification pass
- [ ] Confidence information
- [ ] Hallucination evaluation
- [ ] Long-meeting handling

## Phase 4 — User Experience

- [ ] Live recording
- [ ] Live transcription
- [ ] Desktop application
- [ ] Search
- [ ] Meeting history
- [ ] Human notes

## Phase 5 — Integrations

Potentially:

- [ ] Calendar
- [ ] Jira
- [ ] Slack
- [ ] Notion
- [ ] Obsidian
- [ ] API
- [ ] Webhooks

---

# Guiding Principle

> **Don't build an AI that writes meeting notes. Build a local system that understands meetings.**

The MOM is simply the first useful representation of that understanding.

If the underlying Meeting IR is good enough, the same information can eventually power summaries, action items, project updates, tickets, follow-ups, knowledge bases, and agents.

---

# Current Open Questions

This project is intentionally not fully designed yet.

Important questions to investigate:

1. How much better is Qwen3 vs Gemma 3 on real multilingual meeting transcripts?
2. What is the smallest model that produces reliable Meeting IR?
3. How much does a verification pass improve factual accuracy?
4. Can one LLM efficiently perform extraction, verification, and generation?
5. How should long meetings be chunked?
6. How should speaker diarization interact with ASR?
7. How should evidence be represented?
8. What information should belong in the Meeting IR?
9. When is a database actually necessary?
10. What is the minimum hardware required for a good local experience?

These should be answered experimentally rather than assumed.

---

## Long-Term Vision

```text
                         ┌─────────────────────┐
                         │    Meeting Engine   │
                         │                     │
                         │  Local • Open •     │
                         │  Model Agnostic     │
                         └──────────┬──────────┘
                                    │
                             Meeting IR
                                    │
             ┌──────────────┬───────┼────────┬──────────────┐
             ▼              ▼       ▼        ▼              ▼
            MOM          Actions Decisions  Search      Agents
             │              │       │        │              │
             └──────────────┴───────┴────────┴──────────────┘
                                    │
                                    ▼
                         Meeting Intelligence
```

The project starts as a **local MOM generator**.

The long-term goal is a **local meeting intelligence engine** that other applications can build on.