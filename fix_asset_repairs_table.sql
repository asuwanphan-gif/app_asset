-- ============================================================
-- แก้ปัญหา: ตาราง asset_repairs ไม่มีอยู่จริงในฐานข้อมูล
-- ============================================================
-- พบระหว่างแก้บั๊กลบครุภัณฑ์ (23 ก.ย. 2569): โค้ดในแอปหลายจุดอ้างถึงตาราง
-- "asset_repairs" (ประวัติการซ่อมที่เสร็จแล้ว สำหรับแสดงในรายละเอียดครุภัณฑ์,
-- popup สแกน QR, และพิมพ์ฟอร์ม พ.ด.2 ช่อง "ประวัติการซ่อม") แต่ตารางนี้ไม่เคย
-- ถูกสร้างจริงในฐานข้อมูล ทำให้:
--   1) กด "เพิ่มประวัติการซ่อม" ในหน้ารายละเอียดครุภัณฑ์ → บันทึกไม่สำเร็จ (error)
--   2) เมื่อ "แจ้งซ่อม" แล้วบันทึกผลว่า "ซ่อมได้" → ระบบพยายาม insert ประวัติซ่อม
--      อัตโนมัติแต่ล้มเหลวเงียบๆ (ไม่มี error toast ให้เห็น เพราะโค้ดไม่ได้เช็ค error)
--   3) พ.ด.2 ที่พิมพ์ออกมา ช่อง "ประวัติการซ่อม" ว่างเปล่าเสมอ แม้ครุภัณฑ์จะเคยซ่อมจริง
--
-- รันสคริปต์นี้ใน Supabase SQL Editor เพื่อสร้างตารางที่ขาดไป — โค้ดฝั่งแอปเขียน
-- รองรับ schema นี้ไว้แล้ว ไม่ต้องแก้โค้ดเพิ่ม แค่สร้างตารางให้ตรงกัน
--
-- ⚠️ ข้อจำกัด: ประวัติซ่อมที่เกิดขึ้น "ก่อน" รันสคริปต์นี้ (ที่ระบบพยายามบันทึกแต่ล้มเหลว)
-- กู้คืนไม่ได้แล้ว เพราะไม่เคยถูกบันทึกลงที่ไหนเลย — มีผลกับการซ่อมในอดีตเท่านั้น
-- ตั้งแต่รันสคริปต์นี้เป็นต้นไป ประวัติซ่อมจะถูกบันทึกถูกต้อง
-- ============================================================

CREATE TABLE IF NOT EXISTS public.asset_repairs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id     uuid NOT NULL REFERENCES public.assets(id) ON DELETE CASCADE,
  repair_date  date,
  description  text,
  cost         numeric DEFAULT 0,
  vendor       text,
  notes        text,
  created_by   uuid,
  created_at   timestamptz DEFAULT now()
);

ALTER TABLE public.asset_repairs ENABLE ROW LEVEL SECURITY;

-- กวาด policy เดิม (ถ้ามีจากการรันสคริปต์นี้ซ้ำ) แล้วสร้างใหม่ทั้งชุด
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename='asset_repairs'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.asset_repairs', pol.policyname);
  END LOOP;
END $$;

CREATE POLICY asset_repairs_select ON public.asset_repairs
  FOR SELECT TO authenticated USING (true);

CREATE POLICY asset_repairs_insert ON public.asset_repairs
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY asset_repairs_delete ON public.asset_repairs
  FOR DELETE TO authenticated USING (true);

-- แจ้ง PostgREST ให้ reload schema cache ทันที (ปกติจะรีเฟรชเองภายในไม่กี่วินาที
-- แต่สั่งตรงนี้เพื่อให้ใช้งานได้ทันทีหลังรันสคริปต์)
NOTIFY pgrst, 'reload schema';
