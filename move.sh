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

client_pipeline_id=$(jq -r '.data.organization.projectsNext.nodes[] | select(.title=="Client Pipeline")| .id ' .org_settings)
scheduled_tasks_id=$(jq -r '.data.organization.projectsNext.nodes[] | select(.title=="Scheduled Tasks")| .id ' .org_settings)
cp_approved_status_id=$(jq -r --arg CP_ID ${client_pipeline_id} '.data.organization.projectsNext.nodes[] | select(.id==$CP_ID) | .fields.edges[] | select(.node.name=="Status") | .node.settings | fromjson.options[] | select(.name | contains("Approved")) | .id' .org_settings)

if [[ ! -f .client_pipeline_data ]]; then
  gh api graphql -f query='
  query($client_pipeline_id: ID!) {
    node(id: $client_pipeline_id) {
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
  }' -f client_pipeline_id=${client_pipeline_id} > .client_pipeline_data
fi

approved_issue_ids=$(jq -r --arg CP_STATUS_ID ${cp_approved_status_id} '.data.node.items.nodes[] | select(.fieldValues.nodes[].value==$CP_STATUS_ID) | [.id,.content.id] | join("@")' .client_pipeline_data)

for issue_ids in $approved_issue_ids; do
  echo "Working on ${issue_ids}"

  item_issue_id=${issue_ids%%@*}
  content_issue_id=${issue_ids##*@}

  echo $content_issue_id
  echo $item_issue_id

  # Add issues to Scheduled Tasks Queue
  echo "Adding ${content_issue_id} to Scheduled Tasks Queue"
  gh api graphql -f query='
  mutation($project_id: ID!, $issue_id: ID!) {
    addProjectNextItem(input: {projectId: $project_id contentId: $issue_id}) {
      projectNextItem {
        id
      }
    }
  }' -f project_id=${scheduled_tasks_id} -f issue_id=${content_issue_id}

  if [[ $? -ne 0 ]]; then
    echo "Couldn't add Issue to Scheduled tasks, skipping..."
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
  }' -f project_id=${client_pipeline_id} -f issue_id=${item_issue_id}
done

# Project boards changed, delete cached data for next run
rm .client_pipeline_data

