# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RelationshipDetail do
  use MondekWeb, :html
  import MondekWeb.EvidencePresentation, only: [time: 1]
  alias MondekWeb.{PreviewDetail, PreviewPagination}

  def body(assigns) do
    assigns =
      assign(
        assigns,
        :reviewed,
        assigns.review && (assigns.review["relationship"] || assigns.review["proposal"])
      )

    ~H"""
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "secondary-links"}
      title="Secondary relationships"
    >
      <p>These links record hypotheses about related incidents.</p>
      <p :if={@listing["subject"]["id"] != @incident_id}>
        These relationships apply to the <.link patch={
          @incident_path.(@listing["subject"]["id"], false)
        }>containing Condition</.link>.
      </p>
      <p :if={@message} role="status">{@message}</p>
      <div :if={@review} class="preview-incident-evidence">
        <strong>Review {if @review["proposal"]["action"] == "add", do: "addition", else: "removal"}</strong>
        <p>
          {@reviewed["dimension"]} · {@reviewed["subject"]["type"]} {@reviewed["subject"]["id"]} → {@reviewed[
            "target"
          ]["type"]} {@reviewed["target"]["id"]}
        </p>
        <.matches matches={@review["matches"]} relationship={@reviewed} />
        <p>Reason: {@review["proposal"]["reason"]}</p>
        <p>Notification effect: none</p>
        <button
          type="button"
          phx-target={@target}
          phx-click="apply_relationship"
          phx-value-entity={@entity}
          phx-value-request={@review["proposal"]["request_id"]}
        >Apply {if @review["proposal"]["action"] == "add", do: "addition", else: "removal"}</button>
        <button
          type="button"
          phx-target={@target}
          phx-click="cancel_relationship"
          phx-value-entity={@entity}
        >Cancel review</button>
      </div>
      <div :for={candidate <- @candidates} :if={!@review}>
        <details
          :for={
            dimension <-
              candidate["matches"] |> Enum.map(& &1["dimension"]) |> Enum.uniq()
          }
          id={@id_prefix <> "link-" <> candidate["id"] <> "-" <> dimension}
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
        >
          <summary>Link {candidate["label"]} · {dimension}</summary>
          <form phx-target={@target} phx-submit="review_relationship">
            <input type="hidden" name="entity" value={@entity} />
            <input type="hidden" name="action" value="add" />
            <input type="hidden" name="target_type" value={candidate["type"]} />
            <input type="hidden" name="target_id" value={candidate["id"]} />
            <input type="hidden" name="dimension" value={dimension} />
            <label>Reason <input name="reason" required /></label>
            <button type="submit">Review addition</button>
          </form>
        </details>
      </div>
      <p :if={@listing["total"] == 0}>No recorded links.</p>
      <article :for={link <- @listing["items"]} class="preview-incident-evidence">
        <strong>{link["dimension"]} · {String.replace(link["status"], "_", " ")}</strong>
        <p :for={key <- ["subject", "target"]}>
          {String.capitalize(key)} ·
          <.link patch={@incident_path.(link[key]["id"], link[key]["type"] == "individual")}>{link[
            key
          ]["type"]} {link[key]["id"]}</.link>
          · {link[key]["status"]}
        </p>
        <p>Added by {link["actor"]} · {time(link["inserted_at"])} · {link["reason"]}</p>
        <p :if={link["removed_at"]}>
          Removed by {link["removed_by"]} · {time(link["removed_at"])} · {link["removal_reason"]}
        </p>
        <details
          id={@id_prefix <> "link-evidence-" <> link["id"]}
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
        >
          <summary>Recorded evidence · Revision {link["revision"]}</summary>
          <.matches matches={link["matches"]} relationship={link} />
        </details>
        <details
          :if={link["status"] == "active" && !@review}
          id={@id_prefix <> "remove-link-" <> link["id"]}
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
        >
          <summary>Remove relationship</summary>
          <form phx-target={@target} phx-submit="review_relationship">
            <input type="hidden" name="entity" value={@entity} />
            <input type="hidden" name="action" value="remove" />
            <input type="hidden" name="relationship_id" value={link["id"]} />
            <label>Reason <input name="reason" required /></label>
            <button type="submit">Review removal</button>
          </form>
        </details>
      </article>
      <PreviewPagination.pagination
        page={@listing["page"]}
        size={@listing["page_size"]}
        total={@listing["total"]}
        label="Secondary relationship pages"
        url={fn page -> @page_path.("relationships_page", page) end}
      />
    </PreviewDetail.card>
    """
  end

  defp matches(assigns) do
    ~H"""
    <ul>
      <li :for={match <- @matches}>
        {selector_label(match["depends_on"])} · {timing_label(
          match,
          @relationship["target"]["type"],
          @relationship["subject"]["type"]
        )}
        <ul>
          <li :for={ref <- match["contributors"]}>
            Contributor {ref["incident_id"]} · Opening generation {ref["generation"]} · Scheduled check {ref[
              "assignment_id"
            ]}
          </li>
        </ul>
      </li>
    </ul>
    """
  end

  def selector_label(%{"type" => "condition", "namespace" => ns, "key" => key}),
    do: "Condition #{ns}/#{key}"

  def selector_label(%{"type" => "target", "source_id" => source, "kind" => kind, "key" => key}),
    do: "Target #{source}/#{kind}/#{key}"

  def timing_label(match, candidate_type, subject_type) do
    candidate =
      if candidate_type == "condition" && match["depends_on"]["type"] == "target",
        do: "Matching target contribution",
        else: "Matching episode"

    subject =
      if subject_type == "condition", do: "the declaring contribution", else: "this incident"

    case match["timing"] do
      "overlap" ->
        "#{candidate} was open when #{subject} began"

      "later_opening" ->
        "#{candidate} opened within #{match["window_seconds"]} seconds after #{subject} began"
    end
  end
end
