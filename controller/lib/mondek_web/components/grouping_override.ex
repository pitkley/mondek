# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.GroupingOverride do
  use MondekWeb, :html
  alias MondekWeb.{EvidencePresentation, PreviewDetail}

  def action(%{"active" => true}), do: "allow_grouping"
  def action(_), do: "keep_standalone"

  def body(assigns) do
    ~H"""
    <PreviewDetail.card
      id={@id_prefix <> "grouping-override"}
      level={if @full_page, do: 2, else: 3}
      title="Automatic grouping"
    >
      <div :if={@evaluation}>
        <strong>{if @evaluation["disposition"] == "created",
          do: "Automatically created a case",
          else: "Left for manual review"}</strong>
        <p>
          {decision_reason(@evaluation["reason"])} · {EvidencePresentation.time(
            @evaluation["evaluated_at"]
          )}
        </p>
        <.link :if={@evaluation["case_id"]} navigate={"/incidents/cases/" <> @evaluation["case_id"]}>View correlation case</.link>
      </div>
      <p :if={@subject["id"] != @incident_id}>
        Review this preference on the <.link patch={@incident_path.(@subject["id"], false)}>containing Condition</.link>.
      </p>
      <p :if={@override["active"] && @open}>
        <strong>Keep standalone is active for this episode.</strong>
      </p>
      <p :if={!@open}>This episode has ended.</p>
      <p :if={@override && @open && !@editable && @subject["id"] == @incident_id}>
        This episode belongs to a case. Only standalone episodes can change this preference.
      </p>
      <p :if={@override["reason"]}>
        Last decision · {EvidencePresentation.time(@override["updated_at"])} · {@override["reason"]}
      </p>
      <p :if={@message && @override} role="status">{@message}</p>
      <div :if={@editable && @review}>
        <strong>Review {label(@review["proposal"]["action"])}</strong>
        <p>
          Episode · {@review["proposal"]["subject"]["type"]} {@review["proposal"]["subject"]["id"]}
        </p>
        <p>{@review["proposal"]["reason"]}</p>
        <p>
          {effect(@review["proposal"]["action"])} Notification delivery continues on its current schedule.
        </p>
        <button
          type="button"
          phx-click="apply_override"
          phx-target={@target}
          phx-value-request={@review["proposal"]["request_id"]}
          phx-value-entity={@entity}
        >Apply preference</button>
        <button
          type="button"
          phx-click="cancel_override"
          phx-target={@target}
          phx-value-entity={@entity}
        >Cancel review</button>
      </div>
      <details
        :if={@editable && !@review}
        id={@id_prefix <> "grouping-override-form"}
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
      >
        <summary>{label(action(@override))}</summary>
        <p>{effect(action(@override))}</p>
        <form phx-submit="review_override" phx-target={@target}>
          <input type="hidden" name="entity" value={@entity} />
          <input type="hidden" name="action" value={action(@override)} />
          <label>Reason <input name="reason" required /></label>
          <button type="submit">Review preference</button>
        </form>
      </details>
    </PreviewDetail.card>
    """
  end

  defp decision_reason("unique_approved_parent"), do: "One approved parent matched"
  defp decision_reason("incomplete_search"), do: "The candidate search was incomplete"

  defp decision_reason("conflicting_hints"),
    do: "Contributors declared different dependency hints"

  defp decision_reason("no_match"), do: "No parent matched"
  defp decision_reason("multiple_parents"), do: "Several parents matched"
  defp decision_reason("unapproved_match"), do: "The matching hint had no enabled rule"
  defp decision_reason("operator_override"), do: "An operator kept an episode standalone"
  defp decision_reason("already_grouped"), do: "An episode already belonged to a case"
  defp decision_reason("native_hold"), do: "An acknowledgement or maintenance hold was active"
  defp decision_reason("delivery_history"), do: "Delivery work had already started"
  defp decision_reason(_), do: "The grouping decision requires review"

  defp label("keep_standalone"), do: "Keep standalone"
  defp label("allow_grouping"), do: "Allow automatic grouping"

  defp effect("keep_standalone"),
    do:
      "Block automatic grouping for this episode until you allow grouping again or the episode ends."

  defp effect("allow_grouping"),
    do: "Allow enabled grouping rules to consider this episode again."
end
