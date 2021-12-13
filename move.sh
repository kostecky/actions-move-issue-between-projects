#!/bin/bash

if [[ ! -f .org_settings ]]; then
  gh api graphql -f query='
  query($org: String!) {
    organization(login: $org) {
      name
      projectsNext(first: 10) {
        nodes {
          id
          title
          fields(first: 20) {
            edges {
              node {
                id
                name
                settings
              }
            }
          }
        }
      }
    }
  }' -f org=${GITHUB_ORGANIZATION} > .org_settings
fi

customer_pipeline_id=$(jq -r '.data.organization.projectsNext.nodes[] | select(.title=="Customer Pipeline")| .id ' .org_settings)
scheduled_work_id=$(jq -r '.data.organization.projectsNext.nodes[] | select(.title=="Scheduled Work")| .id ' .org_settings)
cp_approved_status_id=$(jq -r --arg CP_ID ${customer_pipeline_id} '.data.organization.projectsNext.nodes[] | select(.id==$CP_ID) | .fields.edges[] | select(.node.name=="Status") | .node.settings | fromjson.options[] | select(.name | contains("Approved")) | .id' .org_settings)

if [[ ! -f .customer_pipeline_data ]]; then
  gh api graphql -f query='
  query($customer_pipeline_id: ID!) {
    node(id: $customer_pipeline_id) {
      ... on ProjectNext {
        items(first: 100) {
          nodes{
            title
            id
            fieldValues(first: 10) {
              nodes{
                value
                projectField{
                  name
                }
              }
            }
            content {
              ... on Issue {
                id
              }
            }
          }
        }
      }
    }
  }' -f customer_pipeline_id=${customer_pipeline_id} > .customer_pipeline_data
fi

approved_issue_ids=$(jq -r --arg CP_STATUS_ID ${cp_approved_status_id} '.data.node.items.nodes[] | select(.fieldValues.nodes[].value==$CP_STATUS_ID) | [.id,.content.id] | join("@")' .customer_pipeline_data)

for issue_ids in $approved_issue_ids; do
  echo "Working on ${issue_ids}"

  item_issue_id=${issue_ids%%@*}
  content_issue_id=${issue_ids##*@}

  echo $content_issue_id
  echo $item_issue_id

  # Add issues to Scheduled Work Queue
  echo "Adding ${content_issue_id} to Scheduled Work Queue"
  gh api graphql -f query='
  mutation($project_id: ID!, $issue_id: ID!) {
    addProjectNextItem(input: {projectId: $project_id contentId: $issue_id}) {
      projectNextItem {
        id
      }
    }
  }' -f project_id=${scheduled_work_id} -f issue_id=${content_issue_id}

  if [[ $? -ne 0 ]]; then
    echo "Couldn't add Issue to Scheduled work, skipping..."
    continue
  fi

  # Delete issue from Approved in Customer Pipeline IF it's been added
  echo "Deleting ${issue_id} in Customer Pipeline"
  gh api graphql -f query='
  mutation($project_id: ID!, $issue_id: ID!) {
    deleteProjectNextItem(
      input: {
        projectId: $project_id
        itemId: $issue_id
      }
    ) {
      deletedItemId
    }
  }' -f project_id=${customer_pipeline_id} -f issue_id=${item_issue_id}
done

# Project boards changed, delete cached data for next run
rm .customer_pipeline_data

