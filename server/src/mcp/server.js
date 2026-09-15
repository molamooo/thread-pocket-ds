import { ToolError } from "./tools.js";

export const MCP_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
export const MCP_LATEST_PROTOCOL = MCP_PROTOCOL_VERSIONS[0];

const JSON_RPC = {
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internalError: -32603,
};

function rpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id, code, message, data = undefined) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message, ...(data ? { data } : {}) } };
}

/**
 * 自己实现的 MCP Streamable HTTP 传输：
 * 无状态、单次请求单次响应、不提供服务端推送流。
 * 工具定义与说明都在 tools.js / instructions.md 里，不依赖任何 MCP SDK。
 */
export function createMcpHandler({
  tools,
  instructions,
  serverInfo = { name: "thread-pocket", title: "Thread Pocket", version: "0.1.0" },
  logger = console,
}) {
  const toolMap = new Map(tools.map((tool) => [tool.name, tool]));

  function listedTools() {
    return tools.map((tool) => ({
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: tool.inputSchema,
      annotations: tool.annotations ?? { readOnlyHint: false, openWorldHint: false },
    }));
  }

  function callTool(name, args) {
    const tool = toolMap.get(name);
    if (!tool) {
      return {
        isError: true,
        content: [{ type: "text", text: `未知工具：${name}。可用工具：${[...toolMap.keys()].join(", ")}` }],
      };
    }
    try {
      const result = tool.handler(args ?? {});
      return {
        isError: false,
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        structuredContent: result !== null && typeof result === "object" && !Array.isArray(result)
          ? result
          : { value: result },
      };
    } catch (error) {
      if (error instanceof ToolError) {
        return { isError: true, content: [{ type: "text", text: `错误：${error.message}` }] };
      }
      // 仓库层抛出的 HttpError 带着可读的中文信息，直接透出给模型
      if (error && typeof error.status === "number" && typeof error.message === "string") {
        const detail = error.details ? ` ${JSON.stringify(error.details)}` : "";
        const hint = error.code === "revision_conflict"
          ? " 请先重新 get_thread 获取最新 revision，再决定如何合并。"
          : "";
        return {
          isError: true,
          content: [{ type: "text", text: `错误（${error.code ?? error.status}）：${error.message}${detail}.${hint}` }],
        };
      }
      logger.error?.("[thread-pocket] MCP 工具执行失败", error);
      return { isError: true, content: [{ type: "text", text: `工具执行失败：${error.message ?? error}` }] };
    }
  }

  function handleMessage(message) {
    if (message === null || typeof message !== "object" || Array.isArray(message)) {
      return { response: rpcError(null, JSON_RPC.invalidRequest, "请求必须是 JSON-RPC 对象") };
    }
    const { method, params } = message;
    const id = message.id;
    const isNotification = id === undefined || id === null;

    if (typeof method !== "string") {
      return { response: rpcError(id, JSON_RPC.invalidRequest, "缺少 method") };
    }

    switch (method) {
      case "initialize": {
        const requested = params?.protocolVersion;
        const protocolVersion = MCP_PROTOCOL_VERSIONS.includes(requested) ? requested : MCP_LATEST_PROTOCOL;
        return {
          response: rpcResult(id, {
            protocolVersion,
            capabilities: { tools: { listChanged: false } },
            serverInfo,
            instructions,
          }),
        };
      }
      case "notifications/initialized":
      case "notifications/cancelled":
      case "notifications/progress":
        return { notification: true };
      case "ping":
        return { response: rpcResult(id, {}) };
      case "tools/list":
        return { response: rpcResult(id, { tools: listedTools() }) };
      case "tools/call": {
        const name = params?.name;
        if (typeof name !== "string" || !name) {
          return { response: rpcError(id, JSON_RPC.invalidParams, "tools/call 需要 name") };
        }
        const res = callTool(name, params?.arguments ?? {});
        return { response: rpcResult(id, res) };
      }
      default:
        if (isNotification) return { notification: true };
        return { response: rpcError(id, JSON_RPC.methodNotFound, `不支持的方法：${method}`) };
    }
  }

  /**
   * 处理一次 POST /mcp。返回 { status, headers, body }。
   * 协议层错误用 JSON-RPC error；工具执行失败放在 result.isError 里。
   */
  function handle(body) {
    let message;
    if (typeof body === "string") {
      try {
        message = JSON.parse(body);
      } catch {
        return { status: 400, payload: rpcError(null, JSON_RPC.parseError, "请求体不是合法 JSON") };
      }
    } else {
      message = body;
    }

    if (Array.isArray(message)) {
      // MCP 2025-06-18 起不再使用批量请求
      return { status: 400, payload: rpcError(null, JSON_RPC.invalidRequest, "不支持批量请求，请逐条发送") };
    }

    const outcome = handleMessage(message ?? {});
    if (outcome.notification) return { status: 202, payload: null };
    return { status: 200, payload: outcome.response };
  }

  return {
    handle,
    tools: listedTools(),
    instructions,
    serverInfo,
    hasTool: (name) => toolMap.has(name),
  };
}
