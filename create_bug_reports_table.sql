-- ============================================================
-- ตาราง bug_reports — เก็บรายการแจ้งปัญหา/บั๊ก สำหรับรวบรวมเป็นข้อมูลงานวิจัย
-- รันใน Supabase SQL Editor ครั้งเดียว (รันซ้ำได้ ไม่เสียหาย)
-- ============================================================
-- สิทธิ์:  ผู้ใช้ทุกคนที่ login แจ้งได้ (INSERT) และดูเฉพาะรายการของตัวเอง
--          admin ดู/แก้สถานะ/ลบได้ทั้งหมด
-- ============================================================

CREATE TABLE IF NOT EXISTS public.bug_reports (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bug_no        bigint GENERATED ALWAYS AS IDENTITY,
  created_at    timestamptz NOT NULL DEFAULT now(),
  reporter_id   uuid,
  reporter_name text,
  reporter_role text,
  branch_id     uuid,
  title         text NOT NULL,
  bug_type      text,
  module        text,
  severity      text CHECK (severity IN ('critical','high','medium','low')),
  description   text,
  steps         text,
  expected      text,
  actual        text,
  page_open     text,
  user_agent    text,
  screen_size   text,
  status        text NOT NULL DEFAULT 'new' CHECK (status IN ('new','in_progress','resolved','wontfix')),
  resolution    text,
  resolved_at   timestamptz,
  resolved_by   uuid
);

ALTER TABLE public.bug_reports ENABLE ROW LEVEL SECURITY;

-- กวาด policy เดิมทั้งหมดก่อน แล้วสร้างใหม่ทั้งชุด
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='bug_reports'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.bug_reports', pol.policyname);
  END LOOP;
END $$;

CREATE POLICY bug_reports_insert ON public.bug_reports
  FOR INSERT TO authenticated
  WITH CHECK (reporter_id = auth.uid());

CREATE POLICY bug_reports_select ON public.bug_reports
  FOR SELECT TO authenticated
  USING (
    reporter_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

CREATE POLICY bug_reports_update ON public.bug_reports
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

CREATE POLICY bug_reports_delete ON public.bug_reports
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- Supabase จะเลิก auto-grant Data API ให้ตารางใหม่ตั้งแต่ 30 ต.ค. 2569 — ใส่ GRANT ไว้เลย
GRANT SELECT, INSERT, UPDATE, DELETE ON public.bug_reports TO authenticated;
GRANT ALL ON public.bug_reports TO service_role;

NOTIFY pgrst, 'reload schema';
