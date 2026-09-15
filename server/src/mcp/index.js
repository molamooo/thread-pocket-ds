import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createMcpHandler } from "./server.js";
import { createTools } from "./tools.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

let cachedInstructions = null;

/**
 * MCP 的 instructions 就是「skill 描述」本身：
 * Agent 连上来（initialize）就会拿到它，因此不需要再单独分发一份 Skill 包。
 */
export function loadInstructions() {
  if (cachedInstructions === null) {
    cachedInstructions = fs.readFileSync(path.join(HERE, "instructions.md"), "utf8");
  }
  return cachedInstructions;
}

export function createThreadPocketMcp({ repo, views, version = "0.1.0", logger = console }) {
  return createMcpHandler({
    tools: createTools({ repo, views }),
    instructions: loadInstructions(),
    serverInfo: {
      name: "thread-pocket",
      title: "Thread Pocket",
      version,
    },
    logger,
  });
}

export { createMcpHandler } from "./server.js";
