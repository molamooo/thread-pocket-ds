#!/usr/bin/env node
// 打印（或打开）首次初始化账号的链接。
// 只绑本机时其实不需要它：直接访问 /auth/setup 即可。对外部署时才用它。
import { readFile } from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const linkFile = process.env.THREADPOCKET_SETUP_LINK
  ?? path.resolve(HERE, "..", "data", "setup-link.txt");

try {
  const link = (await readFile(linkFile, "utf8")).trim();
  if (!link) throw new Error("链接文件是空的");
  if (process.argv.includes("--print")) {
    console.log(link);
  } else {
    const command = process.platform === "darwin" ? "open" : "xdg-open";
    const child = spawn(command, [link], { stdio: "ignore" });
    child.on("error", () => {
      console.error("无法打开浏览器；用 `npm run setup:link -- --print` 查看链接。");
      process.exitCode = 1;
    });
    child.on("exit", (code) => {
      if (code) process.exitCode = code;
      else console.log(`已在默认浏览器打开初始化页：${link}`);
    });
  }
} catch (error) {
  if (error.code === "ENOENT") {
    console.error(
      [
        `没有找到初始化链接（${linkFile}）。`,
        "可能的原因：账号已经初始化；或服务还没启动过（启动时会生成链接）。",
        "也可以直接访问 http://127.0.0.1:8787/auth/setup（只绑本机时无需凭证）。",
      ].join("\n"),
    );
  } else {
    console.error(error.message);
  }
  process.exitCode = 1;
}
