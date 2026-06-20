-- ============================================================
-- fix_database.sql — App พัสดุ
-- รันทั้งไฟล์นี้ใน Supabase SQL Editor ครั้งเดียว (รันซ้ำได้ ไม่พังของเดิม)
--
-- สิ่งที่ไฟล์นี้ทำ:
--   1. สร้างตาราง transaction_logs (audit log ทุก action สำคัญ)
--   2. สร้าง RPC receive_transfer (SECURITY DEFINER) — รับโอนครุภัณฑ์
--      ข้ามสาขาแบบ atomic แม้ RLS จะบังแถวฝั่ง client
--
-- pattern เดียวกับ fix_database.sql ของ Apps ครุภัณฑ์ด่าน (โปรเจกต์พี่น้อง)
-- ============================================================


-- ============================================================
-- 1) TRANSACTION LOGS
-- ============================================================
CREATE TABLE IF NOT EXISTS transaction_logs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action     text NOT NULL,                 -- เช่น asset_create, transfer_receive, disposal
  detail     jsonb DEFAULT '{}'::jsonb,     -- รายละเอียดเพิ่มเติมของ action
  asset_id   uuid,                          -- อ้างถึงครุภัณฑ์ (ถ้ามี) — ไม่ใส่ FK เพื่อให้ log อยู่ได้แม้ asset ถูกลบ
  user_id    uuid DEFAULT auth.uid(),
  username   text,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_txlog_created ON transaction_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_txlog_asset   ON transaction_logs (asset_id);

ALTER TABLE transaction_logs ENABLE ROW LEVEL SECURITY;

-- กวาด policy เก่าทั้งหมดของ transaction_logs แล้วสร้างใหม่
-- (DB จริงอาจมี policy ค้างไม่ตรง schema — กวาดจาก pg_policies ทุก cmd)
DO $$
DECLARE pol RECORD;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies
             WHERE schemaname = 'public' AND tablename = 'transaction_logs'
  LOOP
    EXECUTE format('DROP POLICY %I ON transaction_logs', pol.policyname);
  END LOOP;
END $$;

-- ทุก user ที่ login แล้ว insert log ได้ / อ่านได้ — ห้ามแก้ไข/ลบจาก client (ไม่มี UPDATE/DELETE policy)
CREATE POLICY txlog_insert ON transaction_logs
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY txlog_select ON transaction_logs
  FOR SELECT TO authenticated USING (true);


-- ============================================================
-- 2) RPC: receive_transfer — รับโอนครุภัณฑ์ข้ามสาขา (atomic)
--
-- ทำไมต้องเป็น RPC: UPDATE ผ่าน Supabase client แตะได้เฉพาะแถวที่
-- ผ่าน SELECT policy ด้วย — สาขาปลายทางมองไม่เห็นครุภัณฑ์ของสาขา
-- ต้นทาง จึงย้าย branch_id จาก client ไม่ได้ (update 0 แถวแบบเงียบ)
-- SECURITY DEFINER ข้าม RLS ได้ โดย guard สิทธิ์เองในฟังก์ชัน
-- ============================================================
CREATE OR REPLACE FUNCTION receive_transfer(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  tr         asset_transfers%ROWTYPE;
  my_role    text;
  my_branch  uuid;
  my_name    text;
  n          int;
BEGIN
  SELECT * INTO tr FROM asset_transfers WHERE id = p_transfer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบรายการโอน';
  END IF;
  IF tr.status <> 'pending' THEN
    RAISE EXCEPTION 'รายการนี้ถูกดำเนินการไปแล้ว (สถานะ: %)', tr.status;
  END IF;

  SELECT role, branch_id, COALESCE(username, full_name)
    INTO my_role, my_branch, my_name
    FROM profiles WHERE id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบโปรไฟล์ผู้ใช้';
  END IF;
  IF my_role <> 'admin' AND (my_branch IS NULL OR my_branch <> tr.to_branch_id) THEN
    RAISE EXCEPTION 'เฉพาะสาขาปลายทางหรือ admin เท่านั้นที่รับโอนได้';
  END IF;

  -- ย้ายครุภัณฑ์ทุกชิ้นในคำขอ — to_jsonb รองรับทั้ง asset_ids ชนิด uuid[] และ jsonb
  UPDATE assets
     SET branch_id = tr.to_branch_id,
         updated_at = now()
   WHERE id IN (
     SELECT (jsonb_array_elements_text(to_jsonb(tr.asset_ids)))::uuid
   );
  GET DIAGNOSTICS n = ROW_COUNT;

  INSERT INTO transaction_logs (action, detail, user_id, username)
  VALUES ('transfer_receive',
          jsonb_build_object('transfer_id', p_transfer_id, 'moved', n),
          auth.uid(), my_name);

  RETURN jsonb_build_object('moved', n);
END $$;

REVOKE ALL ON FUNCTION receive_transfer(uuid) FROM public;
GRANT EXECUTE ON FUNCTION receive_transfer(uuid) TO authenticated;

-- ============================================================
-- 3) FEEDBACK TABLE — ประเมินความพึงพอใจ
-- ============================================================
CREATE TABLE IF NOT EXISTS feedback (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id    uuid,                          -- ไม่ใส่ FK เพื่อความยืดหยุ่น
  user_id      uuid,
  rating       smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  fav_feature  text,
  problems     text,
  suggestions  text,
  created_at   timestamptz DEFAULT now()
);

ALTER TABLE feedback ENABLE ROW LEVEL SECURITY;

-- ลบ policy เก่าก่อน (รันซ้ำได้)
DO $$ DECLARE r record;
BEGIN
  FOR r IN SELECT policyname FROM pg_policies WHERE tablename='feedback' AND schemaname='public' LOOP
    EXECUTE 'DROP POLICY IF EXISTS ' || quote_ident(r.policyname) || ' ON feedback';
  END LOOP;
END $$;

-- ผู้ใช้ที่ login แล้วส่งแบบประเมินได้
CREATE POLICY "feedback_insert" ON feedback FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

-- admin ดูผลประเมินทั้งหมดได้
CREATE POLICY "feedback_admin_select" ON feedback FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
        AND profiles.active = true
    )
  );

-- ============================================================
-- 4) PUBLIC ASSET SCAN RPC — สแกน QR โดยไม่ต้อง login
-- ============================================================
CREATE OR REPLACE FUNCTION public_asset_scan(p_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result json;
BEGIN
  SELECT json_build_object(
    'id',                  a.id,
    'asset_code',          a.asset_code,
    'name',                a.name,
    'brand',               a.brand,
    'model',               a.model,
    'status',              a.status,
    'location',            a.location,
    'price',               a.price,
    'acquired_date',       a.acquired_date,
    'branch_name',         b.name,
    'recent_inspections',  (
      SELECT json_agg(row_to_json(h.*) ORDER BY h.inspected_at DESC)
      FROM (
        SELECT
          ii.status,
          ii.created_at   AS inspected_at,
          ins.name        AS round_name
        FROM inspection_items ii
        LEFT JOIN inspections ins ON ins.id = ii.inspection_id
        WHERE ii.asset_id = a.id
        ORDER BY ii.created_at DESC
        LIMIT 3
      ) h
    )
  ) INTO v_result
  FROM assets a
  LEFT JOIN branches b ON b.id = a.branch_id
  WHERE a.id = p_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public_asset_scan(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public_asset_scan(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public_asset_scan(uuid) TO authenticated;

-- ============================================================
-- เสร็จแล้ว — refresh แอป banner เตือนจะหายไปเอง
-- ============================================================


-- ============================================================
-- [OPTIONAL] ลบ record รหัสเก่า เพื่อนำเข้าใหม่ด้วยรหัสใหม่
--
-- รหัสเก่า: ขึ้นต้นด้วยตัวอักษร (เช่น มรภ.ศก.13.13.1315/59-179)
-- รหัสใหม่: ขึ้นต้นด้วย 4 ตัวเลข-3 ตัวเลข (เช่น 3431-002-0002-66-003)
--
-- วิธีใช้:
--   1. รัน STEP 1 ดูรายการก่อน (SELECT อย่างเดียว ไม่ลบ)
--   2. ถ้าถูกต้อง → uncomment STEP 3 แล้วรัน
-- ============================================================

-- STEP 1: ดูรายการที่ "จะลบ" — ตรวจสอบก่อนเสมอ
SELECT
  a.asset_code,
  a.name,
  b.name AS branch_name,
  a.status,
  a.created_at::date AS imported_date
FROM assets a
LEFT JOIN branches b ON b.id = a.branch_id
WHERE a.asset_code !~ '^\d{4}-\d{3}'   -- รหัสที่ไม่ใช่รูปแบบใหม่
  AND a.status != 'disposed'
ORDER BY a.asset_code;

-- STEP 2: นับ
SELECT
  COUNT(*) AS total_to_delete,
  COUNT(DISTINCT a.branch_id) AS branch_count
FROM assets a
WHERE a.asset_code !~ '^\d{4}-\d{3}'
  AND a.status != 'disposed';

-- STEP 3: ลบ (uncomment ทั้งบล็อกเมื่อแน่ใจแล้ว)
-- ⚠️  ไม่สามารถย้อนกลับได้ — ตรวจสอบ STEP 1 ก่อนเสมอ
/*
BEGIN;

  -- 3a) ลบ inspection_items ที่ผูกกับ asset เหล่านี้
  DELETE FROM inspection_items
  WHERE asset_id IN (
    SELECT id FROM assets
    WHERE asset_code !~ '^\d{4}-\d{3}'
      AND status != 'disposed'
  );

  -- 3b) ลบ transaction_logs ที่ผูกกับ asset เหล่านี้
  DELETE FROM transaction_logs
  WHERE asset_id IN (
    SELECT id FROM assets
    WHERE asset_code !~ '^\d{4}-\d{3}'
      AND status != 'disposed'
  );

  -- 3c) ลบ transfers ที่ผูกกับ asset เหล่านี้ (ถ้ามี)
  DELETE FROM transfers
  WHERE asset_id IN (
    SELECT id FROM assets
    WHERE asset_code !~ '^\d{4}-\d{3}'
      AND status != 'disposed'
  );

  -- 3d) ลบ assets ตัวจริง
  DELETE FROM assets
  WHERE asset_code !~ '^\d{4}-\d{3}'
    AND status != 'disposed';

COMMIT;
*/

-- หลังลบเสร็จ → กลับไปนำเข้า Excel ใหม่ในแอป
-- รหัสใหม่จะถูกสร้างโดยอัตโนมัติจาก 5 คอลัมน์ใน Excel
