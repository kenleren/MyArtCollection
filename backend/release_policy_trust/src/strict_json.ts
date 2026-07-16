import { fail } from "./errors.js";

export interface JsonLimits {
  maxDepth: number;
  maxNodes: number;
}

class Parser {
  private index = 0;
  private nodes = 0;

  constructor(private readonly text: string, private readonly limits: JsonLimits) {}

  parse(): unknown {
    const value = this.value(0);
    this.space();
    if (this.index !== this.text.length) fail("invalid_input", "trailing JSON data");
    return value;
  }

  private node(depth: number): void {
    if (depth > this.limits.maxDepth) fail("overflow", "JSON depth exceeded");
    this.nodes += 1;
    if (this.nodes > this.limits.maxNodes) fail("overflow", "JSON node count exceeded");
  }

  private value(depth: number): unknown {
    this.space();
    this.node(depth);
    const char = this.text[this.index];
    if (char === "{") return this.object(depth + 1);
    if (char === "[") return this.array(depth + 1);
    if (char === '"') return this.string();
    if (char === "t") return this.literal("true", true);
    if (char === "f") return this.literal("false", false);
    if (char === "n") return this.literal("null", null);
    return this.number();
  }

  private object(depth: number): Record<string, unknown> {
    this.index += 1;
    const output: Record<string, unknown> = {};
    const keys = new Set<string>();
    this.space();
    if (this.text[this.index] === "}") { this.index += 1; return output; }
    for (;;) {
      this.space();
      if (this.text[this.index] !== '"') fail("invalid_input", "object key must be a string");
      const key = this.string();
      if (keys.has(key)) fail("invalid_input", "duplicate JSON key");
      keys.add(key);
      this.space();
      if (this.text[this.index] !== ":") fail("invalid_input", "missing JSON colon");
      this.index += 1;
      output[key] = this.value(depth);
      this.space();
      const separator = this.text[this.index++];
      if (separator === "}") return output;
      if (separator !== ",") fail("invalid_input", "invalid JSON object separator");
    }
  }

  private array(depth: number): unknown[] {
    this.index += 1;
    const output: unknown[] = [];
    this.space();
    if (this.text[this.index] === "]") { this.index += 1; return output; }
    for (;;) {
      output.push(this.value(depth));
      this.space();
      const separator = this.text[this.index++];
      if (separator === "]") return output;
      if (separator !== ",") fail("invalid_input", "invalid JSON array separator");
    }
  }

  private string(): string {
    const start = this.index;
    this.index += 1;
    let escaped = false;
    while (this.index < this.text.length) {
      const code = this.text.charCodeAt(this.index);
      if (!escaped && code === 0x22) {
        this.index += 1;
        try { return JSON.parse(this.text.slice(start, this.index)) as string; }
        catch { return fail("invalid_input", "invalid JSON string"); }
      }
      if (!escaped && code < 0x20) fail("invalid_input", "control byte in JSON string");
      if (!escaped && code === 0x5c) escaped = true;
      else escaped = false;
      this.index += 1;
    }
    return fail("invalid_input", "unterminated JSON string");
  }

  private number(): number {
    const tail = this.text.slice(this.index);
    const match = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(tail);
    if (!match) return fail("invalid_input", "invalid JSON value");
    this.index += match[0].length;
    const value = Number(match[0]);
    if (!Number.isFinite(value)) return fail("invalid_input", "non-finite JSON number");
    return value;
  }

  private literal<T>(token: string, value: T): T {
    if (!this.text.startsWith(token, this.index)) fail("invalid_input", "invalid JSON literal");
    this.index += token.length;
    return value;
  }

  private space(): void {
    while (/\s/.test(this.text[this.index] ?? "")) this.index += 1;
  }
}

export function parseStrictJson(bytes: Uint8Array, limits: JsonLimits): unknown {
  let text: string;
  try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { return fail("invalid_input", "body is not valid UTF-8"); }
  return new Parser(text, limits).parse();
}
