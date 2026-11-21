# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.V1.ConfigurationController do
  use MondekWeb.API.Controller
  alias Mondek.Monitoring
  def open_api_operation(:rules), do: MondekWeb.API.Contract.operation(:rules)

  def open_api_operation(:configuration_revision),
    do: MondekWeb.API.Contract.operation(:configuration_revision)

  def open_api_operation(:schema_migration_preview),
    do: MondekWeb.API.Contract.operation(:schema_migration_preview)

  def open_api_operation(:policy_plan), do: MondekWeb.API.Contract.operation(:policy_plan)
  def open_api_operation(:policy_apply), do: MondekWeb.API.Contract.operation(:policy_apply)
  def open_api_operation(:policy_export), do: MondekWeb.API.Contract.operation(:policy_export)
  def open_api_operation(:policy_values), do: MondekWeb.API.Contract.operation(:policy_values)
  def open_api_operation(:rule_seed), do: MondekWeb.API.Contract.operation(:rule_seed)
  def open_api_operation(:rule), do: MondekWeb.API.Contract.operation(:rule)
  def open_api_operation(:rule_preview), do: MondekWeb.API.Contract.operation(:rule_preview)
  def open_api_operation(:rule_apply), do: MondekWeb.API.Contract.operation(:rule_apply)

  def open_api_operation(:exception_preview),
    do: MondekWeb.API.Contract.operation(:exception_preview)

  def open_api_operation(:exception_reset), do: MondekWeb.API.Contract.operation(:exception_reset)
  def open_api_operation(:bulk_select), do: MondekWeb.API.Contract.operation(:bulk_select)
  def open_api_operation(:bulk_prepare), do: MondekWeb.API.Contract.operation(:bulk_prepare)
  def open_api_operation(:bulk_preview), do: MondekWeb.API.Contract.operation(:bulk_preview)
  def open_api_operation(:bulk_apply), do: MondekWeb.API.Contract.operation(:bulk_apply)
  def open_api_operation(:bulk_status), do: MondekWeb.API.Contract.operation(:bulk_status)

  def rules(conn, p), do: reply(conn, Mondek.ConfigurationRules.list(p["page"] || 1))

  def configuration_revision(conn, _params) do
    case Mondek.ConfigurationRepository.read_state() do
      {:ok, state} -> reply(conn, %{head: state.head, installation_id: state.installation_id})
      {:error, reason} -> respond(conn, {:error, reason})
    end
  end

  def policy_plan(conn, p),
    do: respond(conn, Mondek.ConfigurationPolicy.plan(p["manifest"], p["base_head"]))

  def schema_migration_preview(conn, p),
    do: respond(conn, Mondek.SchemaMigrationPreview.preview(conn.body_params, p["page"] || 1))

  def policy_apply(conn, p),
    do: respond(conn, Mondek.ConfigurationPolicy.apply(p["review_token"], p["manifest"]))

  def policy_export(conn, p),
    do: respond(conn, Mondek.ConfigurationPolicy.export(p["project"]))

  def policy_values(conn, p),
    do: respond(conn, Mondek.ConfigurationPolicy.values(p["source_id"], p["page"] || 1))

  def rule_seed(conn, %{"assignment_id" => id}),
    do: respond(conn, Mondek.ConfigurationRules.seed(id))

  def rule(conn, %{"id" => id}), do: respond(conn, Mondek.ConfigurationRules.get(id))

  def rule_preview(conn, p),
    do: respond(conn, Mondek.ConfigurationRules.preview(p["proposal"], p["page"] || 1))

  def rule_apply(conn, p),
    do: respond(conn, Mondek.ConfigurationRules.apply(p["review_token"], p["proposal"]))

  def exception_preview(conn, %{"id" => id} = p),
    do: respond(conn, Mondek.ConfigurationRules.preview_reset(id, integer(p["revision"])))

  def exception_reset(conn, p),
    do: respond(conn, Mondek.ConfigurationRules.reset_exception(p["review_token"]))

  def bulk_select(conn, p),
    do: respond(conn, Monitoring.select_bulk_configuration(p["filters"] || %{}))

  def bulk_prepare(conn, p),
    do: respond(conn, Monitoring.prepare_bulk_configuration(p["selection"], p["page"] || 1))

  def bulk_preview(conn, p),
    do:
      respond(
        conn,
        Monitoring.preview_bulk_configuration(p["prepare_token"], p["params"], p["page"] || 1)
      )

  def bulk_apply(conn, p),
    do: respond(conn, Monitoring.apply_bulk_configuration(p["review_token"], p["params"]))

  def bulk_status(conn, p),
    do: respond(conn, Monitoring.bulk_configuration_status(p["receipts"], p["page"] || 1))
end
