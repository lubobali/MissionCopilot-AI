-- Managers read their organization's missions (#175, ADR 0014). The server sets app.role = 'manager'
-- for one transaction only, and only for a person whose dashboard session says so (db/session.py,
-- as_manager); a phone's request never sets it. Read only: no manager policy writes anything.

DO $$
DECLARE
    name text;
BEGIN
    FOREACH name IN ARRAY ARRAY['missions', 'mission_members', 'packs', 'pack_contents', 'pack_files',
                                'evidence', 'evidence_heads', 'evidence_files', 'facts',
                                'fact_sources', 'reports', 'report_sentences', 'sync_receipts'] LOOP
        EXECUTE format('CREATE POLICY manager_reads ON %I FOR SELECT'
                       ' USING (current_setting(''app.role'', true) = ''manager'')', name);
    END LOOP;
END
$$;
