import * as graphql from 'graphql'

const graphRequest = graphql(process.env.REACT_APP_GRAPHQL_API_ENDPOINT, {
  asJSON: true,
  method: 'post',
});

export default {
  fetch(graph, variables) {
    return graphRequest(graph)(variables);
  },
};

export const isGraphqlErrorResponse
  = error =>
    Array.isArray(error && error.errors) && error.errors.length === 1 && Object.keys(error.errors[0]).length === 1 && 'message' in error.errors[0];

export const getGraphqlErrorMessage
  = error =>
    error.errors[0].message || 'GraphQL error with empty message';

export const isGraphqlAccessDeniedError
  = error =>
    isGraphqlErrorResponse(error) && getGraphqlErrorMessage(error) === 'Unauthorized';
