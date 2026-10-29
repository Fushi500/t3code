import { assert, it } from "@effect/vitest";
import { RunId, ThreadId } from "@t3tools/contracts";
import * as Effect from "effect/Effect";

import { readLatestMessages, type ThreadTools, waitForRun, withEffort } from "./thread.ts";

const threadId = ThreadId.make("thread-1");
const runId = RunId.make("run-1");

/** Answers each tool call with the next scripted response for that tool. */
const scriptedTools = (script: Record<string, Array<unknown>>) => {
  const calls: Array<{ readonly tool: string; readonly args: unknown }> = [];
  const call = ((tool: string, args: unknown) => {
    calls.push({ tool, args });
    const next = script[tool]?.shift();
    return next === undefined ? Effect.die(`unscripted ${tool} call`) : Effect.succeed(next);
  }) as ThreadTools["call"];
  return { tools: { call } satisfies ThreadTools, calls };
};

it.effect("--wait follows the sent run to its continuation's terminal status", () =>
  Effect.gen(function* () {
    const continuation = RunId.make("run-2");
    const { tools, calls } = scriptedTools({
      t3_thread_wait: [
        { threadId, runId, status: "running", timedOut: true },
        { threadId, runId: continuation, status: "failed", timedOut: false },
      ],
      t3_thread_read: [{ thread: { pendingRequestCount: 0 } }],
    });

    const outcome = yield* waitForRun(tools, threadId, runId);

    assert.deepStrictEqual(outcome, { type: "ended", runId: continuation, status: "failed" });
    assert.deepStrictEqual(
      calls.filter((entry) => entry.tool === "t3_thread_wait").map((entry) => entry.args),
      [
        { threadId, runId, timeoutMs: 15_000 },
        { threadId, runId, timeoutMs: 15_000 },
      ],
    );
  }),
);

it.effect("--wait stops when the thread waits for an answer instead of polling forever", () =>
  Effect.gen(function* () {
    const { tools } = scriptedTools({
      t3_thread_wait: [
        { threadId, runId, status: "queued", timedOut: true },
        { threadId, runId, status: "queued", timedOut: true },
      ],
      t3_thread_read: [{ thread: { pendingRequestCount: 1 } }],
    });

    assert.deepStrictEqual(yield* waitForRun(tools, threadId, runId), { type: "needs_input" });
  }),
);

it.effect("--wait reports its run's result when a later run is the one waiting", () =>
  Effect.gen(function* () {
    const { tools } = scriptedTools({
      t3_thread_wait: [
        { threadId, runId, status: "running", timedOut: true },
        { threadId, runId, status: "completed", timedOut: false },
      ],
      t3_thread_read: [{ thread: { pendingRequestCount: 1 } }],
    });

    assert.deepStrictEqual(yield* waitForRun(tools, threadId, runId), {
      type: "ended",
      runId,
      status: "completed",
    });
  }),
);

/** Serves t3_thread_read pages the way the server does: positions count every item. */
const timelineTools = (types: ReadonlyArray<string>) => {
  const items = types.map((type, position) => ({ position, itemId: `item-${position}`, type }));
  const served: Array<number> = [];
  const call = ((_tool: string, input: unknown) => {
    const args = input as { readonly afterPosition?: number; readonly limit: number };
    // Scanning one match past the page keeps reads of huge fixtures linear.
    const matching: typeof items = [];
    for (let position = (args.afterPosition ?? -1) + 1; position < items.length; position++) {
      const item = items[position]!;
      if (["user_message", "assistant_message", "proposed_plan"].includes(item.type)) {
        matching.push(item);
        if (matching.length > args.limit) break;
      }
    }
    const page = matching.slice(0, args.limit);
    served.push(page.length);
    return Effect.succeed({
      thread: { itemCount: items.length },
      items: page,
      nextPosition: page.at(-1)?.position ?? null,
      hasMore: matching.length > page.length,
    });
  }) as ThreadTools["call"];
  const latest = (count: number) =>
    items
      .filter((item) => item.type === "user_message" || item.type === "assistant_message")
      .slice(-count)
      .map((item) => item.itemId);
  return { tools: { call } satisfies ThreadTools, served, latest };
};

const tail = (tools: number) => [...Array<string>(tools).fill("tool_call"), "assistant_message"];

it.effect("show reads the end of a long thread, not its whole history", () =>
  Effect.gen(function* () {
    const { tools, served, latest } = timelineTools([
      ...Array.from({ length: 1000 }, (_, index) =>
        index % 2 === 0 ? "user_message" : "assistant_message",
      ),
      ...Array.from({ length: 10 }, () => tail(30)).flat(),
      "proposed_plan",
    ]);

    const { messages } = yield* readLatestMessages(tools, threadId, 10);

    assert.deepStrictEqual(
      messages.map((item) => item.itemId),
      latest(10),
    );
    assert.isBelow(
      served.reduce((sum, count) => sum + count, 0),
      100,
    );
  }),
);

it.effect("show widens back to the first item when the thread has fewer messages", () =>
  Effect.gen(function* () {
    const { tools, latest } = timelineTools([
      "user_message",
      ...Array.from({ length: 4 }, () => tail(150)).flat(),
    ]);

    const { messages } = yield* readLatestMessages(tools, threadId, 10);

    assert.deepStrictEqual(
      messages.map((item) => item.itemId),
      latest(10),
    );
    assert.lengthOf(messages, 5);
  }),
);

it.effect("show returns a --messages count larger than one call can spread", () =>
  Effect.gen(function* () {
    const { tools, latest } = timelineTools(Array<string>(200_000).fill("assistant_message"));

    const { messages } = yield* readLatestMessages(tools, threadId, 200_000);

    assert.deepStrictEqual(
      messages.map((item) => item.itemId),
      latest(200_000),
    );
  }),
);

const capabilities = {
  providers: [
    {
      providerInstanceId: "codex",
      models: [
        {
          id: "gpt-6.1-sol",
          options: [
            { id: "reasoningEffort", values: ["low", "medium", "high", "xhigh"] },
            { id: "fastMode", values: [false, true] },
          ],
        },
      ],
    },
    {
      providerInstanceId: "claudeAgent",
      models: [
        { id: "claude-opus-5-5", options: [{ id: "effort", values: ["low", "high", "max"] }] },
        { id: "claude-haiku-5-5" },
      ],
    },
  ],
};

it.effect("--effort sets the option the model names its effort with", () =>
  Effect.gen(function* () {
    const { tools, calls } = scriptedTools({
      orchestrator_capabilities: [capabilities, capabilities],
    });

    const codex = yield* withEffort(
      tools,
      {
        instanceId: "codex",
        model: "gpt-6.1-sol",
        options: [
          { id: "reasoningEffort", value: "low" },
          { id: "fastMode", value: true },
        ],
      },
      "high",
    );
    const claude = yield* withEffort(
      tools,
      { instanceId: "claudeAgent", model: "claude-opus-5-5" },
      "max",
    );

    assert.deepStrictEqual(codex.options, [
      { id: "fastMode", value: true },
      { id: "reasoningEffort", value: "high" },
    ]);
    assert.deepStrictEqual(claude.options, [{ id: "effort", value: "max" }]);
    assert.deepStrictEqual(calls[0]?.args, { search: "gpt-6.1-sol" });
  }),
);

it.effect("--effort fails before launching when the model cannot take that level", () =>
  Effect.gen(function* () {
    const { tools } = scriptedTools({
      orchestrator_capabilities: [capabilities, capabilities, capabilities],
    });
    const detail = (instanceId: string, model: string, effort: string) =>
      withEffort(tools, { instanceId, model }, effort).pipe(
        Effect.flip,
        Effect.map((error) => error.message),
      );

    assert.deepStrictEqual(
      [
        yield* detail("claudeAgent", "claude-opus-5-5", "xhigh"),
        yield* detail("claudeAgent", "claude-haiku-5-5", "high"),
        yield* detail("codex", "claude-opus-5-5", "high"),
      ],
      [
        "--effort for claudeAgent/claude-opus-5-5 must be one of: low, high, max.",
        "claudeAgent/claude-haiku-5-5 has no effort setting.",
        "codex/claude-opus-5-5 is not in the server's model list, so its effort levels are unknown.",
      ],
    );
  }),
);
