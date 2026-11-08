ALTER TABLE blender_jobs ADD COLUMN product_id uuid;
ALTER TABLE blender_jobs ADD CONSTRAINT blender_product_owner
 FOREIGN KEY(user_id,product_id) REFERENCES products(user_id,id);
CREATE INDEX blender_product_history ON blender_jobs(user_id,product_id,created_at DESC)
 WHERE product_id IS NOT NULL;
ALTER TABLE blender_jobs DROP CONSTRAINT blender_jobs_source_check;
ALTER TABLE blender_jobs ADD CONSTRAINT blender_jobs_source_check
 CHECK(source IN ('nexus','product','uony'));
