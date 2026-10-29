// Files pilots sent for help: the site owner's scheduled check calls this from the database (pg_net) with the private key
// kept in public.report_settings. It never returns file contents; results go to tables only the database owner can read.
//   { action: "copy" }                          copy waiting files (status new/working) from storage to report_blobs
//   { action: "extract", report_id, pages }     PDF: text and positions of the pages (negative = from the end);
//                                               CSV/TXT: first 80 lines; Excel: first 60 rows; into report_text
//   { action: "cleanup", report_id }            delete the stored file, its copy and extract; mark file_deleted
import { createClient } from "jsr:@supabase/supabase-js@2";
import { encodeBase64, decodeBase64 } from "jsr:@std/encoding@1/base64";
import * as pdfjsMod from "npm:pdfjs-dist@3.11.174/legacy/build/pdf.js";
import * as XLSXMod from "npm:xlsx@0.18.5";
const pdfjs: any = (pdfjsMod as any).getDocument ? pdfjsMod : (pdfjsMod as any).default;
const XLSX: any = (XLSXMod as any).read ? XLSXMod : (XLSXMod as any).default;

Deno.serve(async (req) => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: key } = await sb.from("report_settings").select("value").eq("key", "fn_key").maybeSingle();
  if (!key || req.headers.get("x-report-key") !== key.value) return Response.json({ error: "not allowed" }, { status: 403 });
  const body = await req.json().catch(() => ({}));
  try {
    if (body.action === "copy") {
      const { data: reps, error } = await sb.from("file_reports").select("id,path").eq("file_deleted", false).in("status", ["new", "working"]);
      if (error) throw error;
      const { data: have } = await sb.from("report_blobs").select("report_id");
      const done = new Set((have || []).map((r) => r.report_id));
      let copied = 0, failed = 0;
      for (const r of reps || []) {
        if (done.has(r.id)) continue;
        const f = await sb.storage.from("file-reports").download(r.path);
        if (f.error || !f.data) { failed++; continue; }
        const up = await sb.from("report_blobs").upsert({ report_id: r.id, b64: encodeBase64(new Uint8Array(await f.data.arrayBuffer())) });
        if (up.error) failed++; else copied++;
      }
      return Response.json({ waiting: (reps || []).length, copied, failed });
    }
    if (body.action === "extract") {
      const id = body.report_id, { data: blob } = await sb.from("report_blobs").select("b64").eq("report_id", id).maybeSingle();
      if (!blob) return Response.json({ error: "copy the file first" }, { status: 404 });
      const bytes = decodeBase64(blob.b64), head = new TextDecoder().decode(bytes.slice(0, 5));
      if (head === "%PDF-") {
        const doc = await pdfjs.getDocument({ data: bytes, disableWorker: true, isEvalSupported: false }).promise;
        const want = [...new Set(((body.pages || [1, 2, -2, -1]) as number[]).map((p) => p < 0 ? doc.numPages + 1 + p : p).filter((p) => p >= 1 && p <= doc.numPages))];
        for (const n of want) {
          const pg = await doc.getPage(n), vp = pg.getViewport({ scale: 1 });
          const items = (await pg.getTextContent()).items.filter((it: any) => it.str && it.str.trim())
            .map((it: any) => [it.str, Math.round(it.transform[4] * 10) / 10, Math.round((vp.height - it.transform[5]) * 10) / 10, Math.round(it.width * 10) / 10, Math.round((it.height || 0) * 10) / 10]);
          await sb.from("report_text").upsert({ report_id: id, page: n, items: { kind: "pdf", pages: doc.numPages, w: vp.width, h: vp.height, items } });
        }
        return Response.json({ kind: "pdf", pages: doc.numPages, stored: want });
      }
      if ((bytes[0] === 0x50 && bytes[1] === 0x4b) || (bytes[0] === 0xd0 && bytes[1] === 0xcf)) {
        const wb = XLSX.read(bytes, { type: "array" }), ws = wb.Sheets[wb.SheetNames[0]];
        const rows = XLSX.utils.sheet_to_json(ws, { header: 1, raw: false, defval: "" }).filter((r: any[]) => r.some((c) => String(c).trim())).slice(0, 60);
        await sb.from("report_text").upsert({ report_id: id, page: 0, items: { kind: "excel", sheets: wb.SheetNames, rows } });
        return Response.json({ kind: "excel", rows: rows.length });
      }
      let text = "";
      try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { text = new TextDecoder("windows-1252").decode(bytes); }
      const lines = text.replace(/^﻿/, "").split(/\r?\n/).slice(0, 80);
      await sb.from("report_text").upsert({ report_id: id, page: 0, items: { kind: "text", lines: lines.map((l) => l.slice(0, 600)), total_lines: text.split(/\n/).length } });
      return Response.json({ kind: "text", lines: lines.length });
    }
    if (body.action === "cleanup") {
      const id = body.report_id, { data: r } = await sb.from("file_reports").select("path").eq("id", id).maybeSingle();
      if (!r) return Response.json({ error: "no such report" }, { status: 404 });
      const rm = await sb.storage.from("file-reports").remove([r.path]);
      await sb.from("report_blobs").delete().eq("report_id", id);
      await sb.from("report_text").delete().eq("report_id", id);
      await sb.from("file_reports").update({ file_deleted: true, updated_at: new Date().toISOString() }).eq("id", id);
      return Response.json({ deleted: !rm.error });
    }
    return Response.json({ error: "unknown action" }, { status: 400 });
  } catch (e) {
    return Response.json({ error: String((e as any)?.message || e) }, { status: 500 });
  }
});
