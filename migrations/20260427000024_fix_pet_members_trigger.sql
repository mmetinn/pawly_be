-- Auto-add owner to pet_members when a pet is created
CREATE OR REPLACE FUNCTION public.add_owner_to_pet_members()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.pet_members (pet_id, user_id, role, status, invited_by)
  VALUES (NEW.id, NEW.user_id, 'owner', 'active', NEW.user_id)
  ON CONFLICT (pet_id, user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pet_add_owner
AFTER INSERT ON public.pets
FOR EACH ROW EXECUTE FUNCTION public.add_owner_to_pet_members();

-- Fix free tier limits: vet_chat 3/day, visual_assessment 1/month
UPDATE tier_features SET is_enabled = true, limit_value = 3
WHERE tier_key = 'free' AND feature_key = 'vet_chat_daily';

UPDATE tier_features SET is_enabled = true, limit_value = 1
WHERE tier_key = 'free' AND feature_key = 'visual_assessment_monthly';
