-- Migrate explicit hosted OpenAI selections, including the retired snapshot.
-- The hosted model ID identifies OpenAI when an older selection has no provider.
-- Leave explicit BYOK selections in place. Review ambiguous rows before cutover.
DO $$
DECLARE
    projects_updated BIGINT;
    detectors_updated BIGINT;
    projects_unclassified BIGINT;
    detectors_unclassified BIGINT;
BEGIN
    -- Drain transactions that already read these settings before taking the
    -- migration snapshot. The constraints below then protect the rolling upgrade.
    SET LOCAL lock_timeout = '5s';
    LOCK TABLE "projects", "detectors" IN ACCESS EXCLUSIVE MODE;

    UPDATE "projects"
    SET "rca_model" = 'gpt-5.6-terra'
    WHERE "rca_source" = 'system'
      AND ("rca_provider" IS NULL OR "rca_provider" IN ('OpenAI', 'openai'))
      AND "rca_model" IN ('o4-mini', 'o4-mini-2025-04-16');
    GET DIAGNOSTICS projects_updated = ROW_COUNT;

    UPDATE "detectors"
    SET "detection_model" = 'gpt-5.6-terra'
    WHERE "detection_source" = 'system'
      AND ("detection_provider" IS NULL OR "detection_provider" IN ('OpenAI', 'openai'))
      AND "detection_model" IN ('o4-mini', 'o4-mini-2025-04-16');
    GET DIAGNOSTICS detectors_updated = ROW_COUNT;

    SELECT COUNT(*) INTO projects_unclassified
    FROM "projects"
    WHERE "rca_model" IN ('o4-mini', 'o4-mini-2025-04-16')
      AND NOT ("rca_source" IS NOT DISTINCT FROM 'byok'
        AND NULLIF(BTRIM("rca_provider"), '') IS NOT NULL);

    SELECT COUNT(*) INTO detectors_unclassified
    FROM "detectors"
    WHERE "detection_model" IN ('o4-mini', 'o4-mini-2025-04-16')
      AND NOT ("detection_source" IS NOT DISTINCT FROM 'byok'
        AND NULLIF(BTRIM("detection_provider"), '') IS NOT NULL);

    IF projects_unclassified + detectors_unclassified > 0 THEN
        RAISE EXCEPTION 'Hosted o4-mini retirement requires model source/provider review (projects=%, detectors=%)',
            projects_unclassified, detectors_unclassified;
    END IF;

    -- The old release can still receive saves after the pre-upgrade job commits.
    ALTER TABLE "projects" ADD CONSTRAINT "projects_no_retired_hosted_o4_mini"
        CHECK ("rca_model" NOT IN ('o4-mini', 'o4-mini-2025-04-16')
            OR ("rca_source" IS NOT DISTINCT FROM 'byok'
                AND NULLIF(BTRIM("rca_provider"), '') IS NOT NULL));
    ALTER TABLE "detectors" ADD CONSTRAINT "detectors_no_retired_hosted_o4_mini"
        CHECK ("detection_model" NOT IN ('o4-mini', 'o4-mini-2025-04-16')
            OR ("detection_source" IS NOT DISTINCT FROM 'byok'
                AND NULLIF(BTRIM("detection_provider"), '') IS NOT NULL));

    RAISE LOG 'Hosted o4-mini retirement: projects updated=%, detectors updated=%',
        projects_updated, detectors_updated;
END $$;
