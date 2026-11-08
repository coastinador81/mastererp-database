-- Independent direct Drive instructions may identify several folders in one
-- conversation without creating products. Keep one open selector per thread,
-- while every identified folder retains its own intake and material job.
DROP INDEX uony_product_intakes_active;
CREATE UNIQUE INDEX uony_product_intakes_active ON uony_product_intakes(user_id,thread_id)
    WHERE status='selecting';
