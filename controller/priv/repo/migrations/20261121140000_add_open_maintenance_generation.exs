# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddOpenMaintenanceGeneration do
  use Ecto.Migration

  def up do
    alter table(:maintenance_series) do
      add :next_index, :integer
      add :refill_at, :utc_datetime_usec
      add :generated_through_at, :utc_datetime_usec
      add :generation_stopped_at, :utc_datetime_usec
      add :generation_issue, :text
    end

    create index(:maintenance_series, [:refill_at], where: "refill_at IS NOT NULL")

    create constraint(:maintenance_series, :maintenance_generation_shape,
             check: """
             (next_index IS NULL AND refill_at IS NULL AND generated_through_at IS NULL
               AND generation_stopped_at IS NULL AND generation_issue IS NULL)
             OR (next_index IS NOT NULL AND next_index > 0 AND generated_through_at IS NOT NULL
               AND ((refill_at IS NOT NULL AND generation_stopped_at IS NULL AND generation_issue IS NULL)
                 OR (refill_at IS NULL AND (generation_stopped_at IS NOT NULL OR generation_issue IS NOT NULL))))
             """
           )

    drop constraint(:maintenance_windows, :maintenance_series_membership)

    create constraint(:maintenance_windows, :maintenance_series_membership,
             check: """
             (series_id IS NULL AND series_index IS NULL)
             OR (series_id IS NOT NULL AND series_index IS NOT NULL AND series_index >= 1)
             """
           )

    execute("""
    CREATE FUNCTION public.maintenance_validate_series_index() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.series_index > 52 AND NOT EXISTS (
        SELECT 1 FROM maintenance_series WHERE id=NEW.series_id AND next_index IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'finite maintenance series index must be in 1..52'
          USING ERRCODE='check_violation';
      END IF;
      RETURN NEW;
    END
    $$;
    """)

    execute("""
    CREATE TRIGGER maintenance_finite_series_index BEFORE INSERT OR UPDATE OF series_id, series_index
    ON maintenance_windows FOR EACH ROW WHEN (NEW.series_index > 52)
    EXECUTE FUNCTION public.maintenance_validate_series_index()
    """)
  end

  def down do
    raise "Open-ended maintenance requires this schema. Restore a pre-upgrade backup to roll back."
  end
end
