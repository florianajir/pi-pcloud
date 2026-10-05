/**
 * The family assistant's window on each person's own Nextcloud.
 *
 * Every tool acts as the person whose agent calls it: the account and its app
 * password are picked from the calling agent's id, never from anything the
 * model says, so one person's agent cannot reach another's files. The app
 * passwords are minted by scripts/openclaw-bootstrap.py and read here at call
 * time, from a directory outside every workspace. Nothing is ever deleted,
 * moved, shared or overwritten.
 *
 * Every parameter is a plain string: agentgateway hands tool schemas to Gemini
 * as they are, and Gemini rejects JSON-Schema keywords such as
 * exclusiveMinimum - which once failed every request of every agent.
 */

import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, realpath, stat, writeFile } from "node:fs/promises";
import path from "node:path";

// Shipped in the OpenClaw image this runs in: an XML parser for WebDAV, the
// untrusted-content envelope OpenClaw wraps web results in, and its own PDF
// extractor. A version that moves them fails the tool call, not the gateway.
const XML_MODULE = "/app/node_modules/linkedom/esm/index.js";
const ENVELOPE_MODULE = "/app/dist/run-external-content.runtime.js";
const PDF_MODULE = "/app/dist/extensions/document-extract/document-extractor.runtime.js";

// Under media/, which openclaw-sync.py keeps out of Forgejo and prunes weekly.
const FETCH_DIR = "media/nextcloud";
const MAX_FETCH_BYTES = 20 * 1024 * 1024;
const MAX_SAVE_BYTES = 50 * 1024 * 1024;
const MAX_INLINE_IMAGE_BYTES = 5 * 1024 * 1024;
const MAX_TEXT_CHARS = 60_000;
const MAX_LISTED = 200;
const MAX_FOUND = 25;
const MAX_SEARCH_WORDS = 4;
const PDF_MAX_PAGES = 20;
const PDF_MAX_PAGE_IMAGES = 5;
const IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"]);
const TEXT_EXTENSIONS = new Set([".txt", ".md", ".csv", ".json", ".xml", ".html", ".yaml", ".yml", ".ics", ".vcf"]);
// OpenClaw stores an attachment as <name>---<uuid>.<ext>.
const SAVED_MEDIA_SUFFIX = /---[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=\.[^./]+$|$)/i;
const PROPFIND_BODY = `<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:"><d:prop>
<d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/>
</d:prop></d:propfind>`;

function accountFor(config, agentId) {
  const user = config?.accounts?.[agentId];
  if (!user || !config.tokenDir) return null;
  const secretFile = path.join(config.tokenDir, agentId);
  return existsSync(secretFile) ? { user, secretFile } : null;
}

function remoteSegments(value) {
  const segments = String(value ?? "")
    .replaceAll("\\", "/")
    .split("/")
    .filter((segment) => segment !== "" && segment !== ".");
  if (segments.some((segment) => segment === ".." || /[\u0000-\u001f]/.test(segment))) {
    throw new Error("A Nextcloud path cannot contain '..' or control characters.");
  }
  return segments;
}

function folded(text) {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}

function originalName(file) {
  return path.basename(file).replace(SAVED_MEDIA_SUFFIX, "");
}

function withCopyNumber(name, number) {
  const extension = path.extname(name);
  return `${name.slice(0, name.length - extension.length)} (${number})${extension}`;
}

// By local name, whatever prefix the server picked. querySelectorAll, because
// linkedom's getElementsByTagName("*") finds nothing in an XML document.
function byLocalName(node, name) {
  return [...node.querySelectorAll("*")].filter((element) => element.tagName.split(":").pop() === name);
}

function textResult(text, details = {}) {
  return { content: [{ type: "text", text }], details };
}

class Nextcloud {
  constructor(baseUrl, user, secret) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.user = user;
    this.authorization = `Basic ${Buffer.from(`${user}:${secret}`).toString("base64")}`;
  }

  static async open(config, account) {
    const secret = (await readFile(account.secretFile, "utf8")).trim();
    return new Nextcloud(config.baseUrl, account.user, secret);
  }

  fileUrl(segments) {
    const encoded = segments.map(encodeURIComponent).join("/");
    return `${this.baseUrl}/remote.php/dav/files/${encodeURIComponent(this.user)}/${encoded}`;
  }

  async request(method, url, { headers = {}, body } = {}) {
    const response = await fetch(url, {
      method,
      headers: { Authorization: this.authorization, ...headers },
      body,
      redirect: "manual",
      signal: AbortSignal.timeout(60_000),
    });
    if (response.status === 401) {
      throw new Error("Nextcloud refused the assistant's app password; it may have been revoked.");
    }
    return response;
  }

  async describe(segments) {
    const response = await this.request("PROPFIND", this.fileUrl(segments), {
      headers: { Depth: "0", "Content-Type": "application/xml" },
      body: PROPFIND_BODY,
    });
    if (response.status === 404) return null;
    if (response.status !== 207) throw new Error(`Nextcloud answered ${response.status} reading "${segments.join("/")}".`);
    const [entry] = await this.parseEntries(await response.text());
    return entry ?? null;
  }

  async list(segments) {
    const response = await this.request("PROPFIND", this.fileUrl(segments), {
      headers: { Depth: "1", "Content-Type": "application/xml" },
      body: PROPFIND_BODY,
    });
    if (response.status === 404) throw new Error(`There is no folder "${segments.join("/") || "/"}".`);
    if (response.status !== 207) throw new Error(`Nextcloud answered ${response.status} listing "${segments.join("/")}".`);
    // The first entry is the folder itself.
    return (await this.parseEntries(await response.text())).slice(1);
  }

  async parseEntries(xml) {
    const { DOMParser } = await import(XML_MODULE);
    const document = new DOMParser().parseFromString(xml, "text/xml");
    return byLocalName(document, "response").map((response) => {
      const value = (name) => byLocalName(response, name)[0]?.textContent?.trim() ?? "";
      const href = value("href").replace(/\/+$/, "");
      return {
        name: decodeURIComponent(href.split("/").pop() ?? ""),
        folder: byLocalName(response, "collection").length > 0,
        size: Number(value("getcontentlength")) || 0,
        modified: value("getlastmodified"),
        type: value("getcontenttype"),
      };
    });
  }

  async search(query) {
    const words = [...new Set(query.split(/\s+/).filter(Boolean))].slice(0, MAX_SEARCH_WORDS);
    if (words.length === 0) throw new Error("Give at least one word to look for.");
    // Nextcloud matches one term against file names only. Each word is asked
    // for on its own, and a result is kept when every word appears somewhere
    // in its path - so "spec énergie" finds Documents/Énergie/Spec.pdf.
    const found = new Map();
    for (const word of words) {
      const url = `${this.baseUrl}/ocs/v2.php/search/providers/files/search?term=${encodeURIComponent(word)}&limit=100`;
      const response = await this.request("GET", url, {
        headers: { "OCS-APIRequest": "true", Accept: "application/json" },
      });
      if (response.status !== 200) throw new Error(`Nextcloud search answered ${response.status}.`);
      for (const entry of (await response.json())?.ocs?.data?.entries ?? []) {
        const entryPath = String(entry?.attributes?.path ?? "");
        if (entryPath) found.set(entryPath, String(entry?.icon ?? "").includes("folder"));
      }
    }
    const wanted = words.map(folded);
    return [...found]
      .filter(([entryPath]) => wanted.every((word) => folded(entryPath).includes(word)))
      .slice(0, MAX_FOUND)
      .map(([entryPath, folder]) => ({ path: entryPath, folder }));
  }

  async ensureFolders(segments) {
    for (let depth = 1; depth <= segments.length; depth += 1) {
      const response = await this.request("MKCOL", this.fileUrl(segments.slice(0, depth)));
      // 405: it already exists.
      if (response.status !== 201 && response.status !== 405) {
        throw new Error(`Nextcloud answered ${response.status} creating "${segments.slice(0, depth).join("/")}".`);
      }
    }
  }

  async freeName(segments) {
    const folder = segments.slice(0, -1);
    const name = segments[segments.length - 1];
    for (let number = 1; number <= 100; number += 1) {
      const candidate = [...folder, number === 1 ? name : withCopyNumber(name, number)];
      if ((await this.describe(candidate)) === null) return candidate;
    }
    throw new Error(`Too many files named "${name}" in that folder.`);
  }
}

async function wrapUntrusted(text, source) {
  const { buildSafeExternalPrompt } = await import(ENVELOPE_MODULE);
  return buildSafeExternalPrompt({
    content: text.slice(0, MAX_TEXT_CHARS),
    source: "unknown",
    subject: `Nextcloud file ${source}`,
  });
}

async function extractPdf(buffer) {
  const { extractPdfContent } = await import(PDF_MODULE);
  return extractPdfContent(
    { buffer: new Uint8Array(buffer), maxPages: PDF_MAX_PAGES, minTextChars: 200, maxPixels: 4_000_000 },
    { throwIfCancelled() {}, runNativeSection: (section) => section() },
  );
}

function searchTool({ config, account }) {
  return {
    name: "nextcloud_search",
    label: "Nextcloud search",
    description:
      "Find files and folders by name in the person's own Nextcloud. Matches names and folder paths, not the text inside documents. Returns paths to use with nextcloud_fetch or nextcloud_list.",
    parameters: {
      type: "object",
      properties: { query: { type: "string", description: "Words from the file or folder name, e.g. \"facture edf\"." } },
      required: ["query"],
      additionalProperties: false,
    },
    async execute(_id, params) {
      const found = await (await Nextcloud.open(config, account)).search(String(params?.query ?? ""));
      if (found.length === 0) return textResult("Nothing in Nextcloud has a name with all of those words.", { found: [] });
      const lines = found.map((entry) => `${entry.path}${entry.folder ? " (folder)" : ""}`);
      return textResult(`Found in Nextcloud:\n${lines.join("\n")}`, { found });
    },
  };
}

function listTool({ config, account }) {
  return {
    name: "nextcloud_list",
    label: "Nextcloud list",
    description: "List a folder of the person's own Nextcloud. Leave folder empty for the top level.",
    parameters: {
      type: "object",
      properties: { folder: { type: "string", description: "Folder path, e.g. \"Documents/Impôts\"." } },
      additionalProperties: false,
    },
    async execute(_id, params) {
      const segments = remoteSegments(params?.folder);
      const entries = await (await Nextcloud.open(config, account)).list(segments);
      const shown = entries.slice(0, MAX_LISTED).map((entry) =>
        entry.folder ? `${entry.name}/` : `${entry.name} (${entry.size} bytes, ${entry.modified})`,
      );
      const more = entries.length > MAX_LISTED ? `\n… and ${entries.length - MAX_LISTED} more` : "";
      const where = segments.join("/") || "the top level";
      return textResult(
        shown.length ? `In ${where}:\n${shown.join("\n")}${more}` : `${where} is empty.`,
        { count: entries.length },
      );
    },
  };
}

function fetchTool({ config, account, workspaceDir }) {
  return {
    name: "nextcloud_fetch",
    label: "Nextcloud fetch",
    description:
      "Fetch a file from the person's own Nextcloud: you get the text of a PDF or text file, or see an image, and a copy is placed in your workspace that the message tool can send to the person.",
    parameters: {
      type: "object",
      properties: { path: { type: "string", description: "File path in Nextcloud, as nextcloud_search or nextcloud_list gave it." } },
      required: ["path"],
      additionalProperties: false,
    },
    async execute(_id, params) {
      const segments = remoteSegments(params?.path);
      if (segments.length === 0) throw new Error("Give the path of a file.");
      const nextcloud = await Nextcloud.open(config, account);
      const entry = await nextcloud.describe(segments);
      if (!entry) throw new Error(`There is no file "${segments.join("/")}" in Nextcloud.`);
      if (entry.folder) throw new Error(`"${segments.join("/")}" is a folder; use nextcloud_list.`);
      if (entry.size > MAX_FETCH_BYTES) throw new Error(`That file is ${entry.size} bytes, over the ${MAX_FETCH_BYTES}-byte limit.`);
      const response = await nextcloud.request("GET", nextcloud.fileUrl(segments));
      if (response.status !== 200) throw new Error(`Nextcloud answered ${response.status} fetching it.`);
      const buffer = Buffer.from(await response.arrayBuffer());

      const name = segments[segments.length - 1];
      const relative = path.posix.join(FETCH_DIR, randomUUID(), name);
      await mkdir(path.dirname(path.join(workspaceDir, relative)), { recursive: true });
      await writeFile(path.join(workspaceDir, relative), buffer);

      const remote = segments.join("/");
      const type = (entry.type || response.headers.get("content-type") || "").split(";")[0].trim();
      const content = [
        {
          type: "text",
          text: `Fetched "${remote}" (${buffer.length} bytes). To give the file to the person, send it with the message tool, filePath "${relative}".`,
        },
      ];
      const extension = path.extname(name).toLowerCase();
      if (IMAGE_TYPES.has(type) && buffer.length <= MAX_INLINE_IMAGE_BYTES) {
        content.push({ type: "image", data: buffer.toString("base64"), mimeType: type });
      } else if (type === "application/pdf" || extension === ".pdf") {
        const pdf = await extractPdf(buffer);
        if (pdf.text?.trim()) content.push({ type: "text", text: await wrapUntrusted(pdf.text, remote) });
        for (const image of (pdf.images ?? []).slice(0, PDF_MAX_PAGE_IMAGES)) content.push(image);
      } else if (type.startsWith("text/") || TEXT_EXTENSIONS.has(extension)) {
        content.push({ type: "text", text: await wrapUntrusted(buffer.toString("utf8"), remote) });
      }
      return { content, details: { path: remote, workspacePath: relative, bytes: buffer.length } };
    },
  };
}

function saveTool({ config, account, workspaceDir }) {
  return {
    name: "nextcloud_save",
    label: "Nextcloud save",
    description:
      "Save a file from your workspace into the person's own Nextcloud - an attachment they sent (the path it arrived with) or a note you wrote. Missing folders are created; an existing file is never replaced, the new one gets a number instead.",
    parameters: {
      type: "object",
      properties: {
        file: { type: "string", description: "Path of the file in your workspace." },
        destination: {
          type: "string",
          description: "Nextcloud folder, ending with \"/\" (e.g. \"Documents/Factures/\"), or a full file path.",
        },
      },
      required: ["file", "destination"],
      additionalProperties: false,
    },
    async execute(_id, params) {
      const workspace = await realpath(workspaceDir);
      const source = await realpath(path.resolve(workspace, String(params?.file ?? ""))).catch(() => null);
      if (!source || !source.startsWith(workspace + path.sep)) {
        throw new Error("Only a file inside your workspace can be saved.");
      }
      const info = await stat(source);
      if (!info.isFile()) throw new Error("That path is not a file.");
      if (info.size > MAX_SAVE_BYTES) throw new Error(`That file is ${info.size} bytes, over the ${MAX_SAVE_BYTES}-byte limit.`);

      const nextcloud = await Nextcloud.open(config, account);
      const destination = String(params?.destination ?? "");
      let target = remoteSegments(destination);
      const intoFolder =
        target.length === 0 || /[\\/]$/.test(destination) || (await nextcloud.describe(target))?.folder === true;
      if (intoFolder) target = [...target, originalName(source)];
      await nextcloud.ensureFolders(target.slice(0, -1));
      target = await nextcloud.freeName(target);
      // If-None-Match closes the gap between freeName's check and this write:
      // a file that appeared meanwhile is refused (412), never replaced.
      const response = await nextcloud.request("PUT", nextcloud.fileUrl(target), {
        headers: { "If-None-Match": "*" },
        body: await readFile(source),
      });
      if (response.status === 412) {
        throw new Error(`A file named "${target.join("/")}" appeared while saving; nothing was replaced, try again.`);
      }
      if (response.status !== 201) {
        throw new Error(`Nextcloud answered ${response.status} saving it.`);
      }
      return textResult(`Saved in the person's Nextcloud as "${target.join("/")}".`, { path: target.join("/") });
    },
  };
}

const TOOLS = {
  nextcloud_search: searchTool,
  nextcloud_list: listTool,
  nextcloud_fetch: fetchTool,
  nextcloud_save: saveTool,
};

export default {
  id: "nextcloud",
  name: "Nextcloud",
  description: "Find, read and save files in the person's own Nextcloud, as that person.",
  register(api) {
    for (const [name, build] of Object.entries(TOOLS)) {
      api.registerTool(
        (ctx) => {
          // No account - the family room's agent, someone without Nextcloud -
          // means no tool at all, rather than one that fails.
          const account = accountFor(api.pluginConfig, ctx?.agentId);
          if (!account || !ctx?.workspaceDir) return null;
          return build({ config: api.pluginConfig, account, workspaceDir: ctx.workspaceDir });
        },
        { names: [name] },
      );
    }
  },
};
