# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ProviderDecisionDetail do
  use MondekWeb, :html
  alias MondekWeb.{EvidencePresentation, PreviewDetail}

  def body(assigns) do
    ~H"""
    <PreviewDetail.card
      id={@id_prefix <> "provider-decisions"}
      level={if @full_page, do: 2, else: 3}
      title="Provider decisions"
    >
      <p :if={!@listing["provider"]}>No advisory provider is available.</p>
      <p :if={@listing["provider"]}>
        Advisory provider · {@listing["provider"]["id"]} · {@listing["provider"]["destination"]}
      </p>
      <p :if={@listing["subject"]["id"] != @incident_id}>
        Decisions apply to the <.link patch={@incident_path.(@listing["subject"]["id"], false)}>containing Condition</.link>.
      </p>
      <div :if={
        @listing["requestable"] && !Enum.any?(@listing["items"], &(&1["status"] == "pending"))
      }>
        <p>
          Send candidate handles and search status<span :if={@listing["provider"]["evidence"] != []}> with {Enum.join(
            @listing["provider"]["evidence"],
            ", "
          )}</span>
          to this provider. Grouping requires a separate operator review.
        </p>
        <button
          type="button"
          phx-click="request_provider_decision"
          phx-target={@target}
          phx-value-entity={@entity}
          phx-value-request={@request_id}
        >Request provider decision</button>
      </div>
      <p :if={@message} role="status">{@message}</p>
      <div :if={@review} class="preview-incident-evidence">
        <.decision_review
          request_id={elem(@review, 0)}
          report={elem(@review, 1)}
          entity={@entity}
          target={@target}
        />
      </div>
      <article :for={row <- @listing["items"]} class="preview-incident-evidence">
        <strong>{status(row["status"])} · {row["provider_id"]}</strong>
        <p>
          Requested {EvidencePresentation.time(row["requested_at"])} · Expires {EvidencePresentation.time(
            row["expires_at"]
          )}
        </p>
        <p :if={row["reason"]}>{row["reason"]}</p>
        <p :if={!is_nil(row["confidence"])}>Provider confidence · {row["confidence"]}</p>
        <p :if={row["selected"]}>
          Selected parent ·
          <.link patch={
            @incident_path.(row["selected"]["id"], row["selected"]["type"] == "individual")
          }>{row["selected"]["type"]} {row["selected"]["id"]}</.link>
        </p>
        <.link :if={row["case_id"]} navigate={"/incidents/cases/" <> row["case_id"]}>View correlation case</.link>
        <button
          :if={
            row["status"] == "proposed" && row["provider_id"] == @listing["provider"]["id"] &&
              @listing["requestable"] && !@review
          }
          type="button"
          phx-click="review_provider_decision"
          phx-target={@target}
          phx-value-entity={@entity}
          phx-value-request={row["request_id"]}
        >Review proposed grouping</button>
      </article>
      <nav :if={@listing["page"] > 1 || @listing["has_more"]} aria-label="Provider decision pages">
        <.link :if={@listing["page"] > 1} patch={@page_path.("decisions_page", @listing["page"] - 1)}>Previous</.link>
        Page {@listing["page"]}
        <.link :if={@listing["has_more"]} patch={@page_path.("decisions_page", @listing["page"] + 1)}>Next</.link>
      </nav>
    </PreviewDetail.card>
    """
  end

  defp decision_review(assigns) do
    ~H"""
    <strong>Review proposed grouping</strong>
    <p :if={@report["proposal"]["action"] == "create"}>
      Create the case “{@report["proposal"]["title"]}”.
    </p>
    <p :if={@report["proposal"]["action"] == "attach"}>
      Attach the episode to case {@report["proposal"]["case_id"]}.
    </p>
    <p :for={ref <- @report["proposal"]["episodes"]}>Episode · {ref["type"]} {ref["id"]}</p>
    <p>
      Selected parent · {@report["decision"]["selected"]["type"]} {@report["decision"]["selected"][
        "id"
      ]}
    </p>
    <p :if={@report["decision"]["reason"]}>Provider reason · {@report["decision"]["reason"]}</p>
    <p>{@report["proposal"]["reason"]}</p>
    <button
      type="button"
      phx-click="apply_provider_decision"
      phx-target={@target}
      phx-value-entity={@entity}
      phx-value-request={@request_id}
    >Apply reviewed grouping</button>
    <button
      type="button"
      phx-click="cancel_provider_decision"
      phx-target={@target}
      phx-value-entity={@entity}
    >Cancel review</button>
    """
  end

  defp status("pending"), do: "Waiting for provider"
  defp status("proposed"), do: "Grouping proposed"
  defp status("standalone"), do: "Provider suggested keeping standalone"
  defp status("abstained"), do: "Provider abstained"
  defp status("expired"), do: "Request expired"
  defp status("revoked"), do: "Disclosure authorization changed"
  defp status("stale"), do: "Proposal is stale"
  defp status("invalid"), do: "Invalid provider response"
  defp status("unavailable"), do: "Provider unavailable"
  defp status("applied"), do: "Reviewed grouping applied"
  defp status(value), do: value
end
