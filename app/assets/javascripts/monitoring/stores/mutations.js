import Vue from 'vue';
import { slugify } from '~/lib/utils/text_utility';
import * as types from './mutation_types';
import { normalizeMetric, normalizeQueryResult } from './utils';
import { BACKOFF_TIMEOUT } from '../../lib/utils/common_utils';
import { metricStates } from '../constants';
import httpStatusCodes from '~/lib/utils/http_status';

const normalizePanelMetrics = (metrics, defaultLabel) =>
  metrics.map(metric => ({
    ...normalizeMetric(metric),
    label: metric.label || defaultLabel,
  }));

/**
 * Locate and return a metric in the dashboard by its id
 * as generated by `uniqMetricsId()`.
 * @param {String} metricId Unique id in the dashboard
 * @param {Object} dashboard Full dashboard object
 */
const findMetricInDashboard = (metricId, dashboard) => {
  let res = null;
  dashboard.panel_groups.forEach(group => {
    group.panels.forEach(panel => {
      panel.metrics.forEach(metric => {
        if (metric.metric_id === metricId) {
          res = metric;
        }
      });
    });
  });
  return res;
};

/**
 * Set a new state for a metric.
 *
 * Initally metric data is not populated, so `Vue.set` is
 * used to add new properties to the metric.
 *
 * @param {Object} metric - Metric object as defined in the dashboard
 * @param {Object} state - New state
 * @param {Array|null} state.result - Array of results
 * @param {String} state.error - Error code from metricStates
 * @param {Boolean} state.loading - True if the metric is loading
 */
const setMetricState = (metric, { result = null, loading = false, state = null }) => {
  Vue.set(metric, 'result', result);
  Vue.set(metric, 'loading', loading);
  Vue.set(metric, 'state', state);
};

/**
 * Maps a backened error state to a `metricStates` constant
 * @param {Object} error - Error from backend response
 */
const emptyStateFromError = error => {
  if (!error) {
    return metricStates.UNKNOWN_ERROR;
  }

  // Special error responses
  if (error.message === BACKOFF_TIMEOUT) {
    return metricStates.TIMEOUT;
  }

  // Axios error responses
  const { response } = error;
  if (response && response.status === httpStatusCodes.SERVICE_UNAVAILABLE) {
    return metricStates.CONNECTION_FAILED;
  } else if (response && response.status === httpStatusCodes.BAD_REQUEST) {
    // Note: "error.response.data.error" may contain Prometheus error information
    return metricStates.BAD_QUERY;
  }

  return metricStates.UNKNOWN_ERROR;
};

export default {
  /**
   * Dashboard panels structure and global state
   */
  [types.REQUEST_METRICS_DATA](state) {
    state.emptyState = 'loading';
    state.showEmptyState = true;
  },
  [types.RECEIVE_METRICS_DATA_SUCCESS](state, dashboard) {
    state.dashboard = {
      ...dashboard,
      panel_groups: dashboard.panel_groups.map((group, i) => {
        const key = `${slugify(group.group || 'default')}-${i}`;
        let { panels = [] } = group;

        // each panel has metric information that needs to be normalized
        panels = panels.map(panel => ({
          ...panel,
          metrics: normalizePanelMetrics(panel.metrics, panel.y_label),
        }));

        return {
          ...group,
          panels,
          key,
        };
      }),
    };

    if (!state.dashboard.panel_groups.length) {
      state.emptyState = 'noData';
    }
  },
  [types.RECEIVE_METRICS_DATA_FAILURE](state, error) {
    state.emptyState = error ? 'unableToConnect' : 'noData';
    state.showEmptyState = true;
  },

  /**
   * Deployments and environments
   */
  [types.RECEIVE_DEPLOYMENTS_DATA_SUCCESS](state, deployments) {
    state.deploymentData = deployments;
  },
  [types.RECEIVE_DEPLOYMENTS_DATA_FAILURE](state) {
    state.deploymentData = [];
  },
  [types.REQUEST_ENVIRONMENTS_DATA](state) {
    state.environmentsLoading = true;
  },
  [types.RECEIVE_ENVIRONMENTS_DATA_SUCCESS](state, environments) {
    state.environmentsLoading = false;
    state.environments = environments;
  },
  [types.RECEIVE_ENVIRONMENTS_DATA_FAILURE](state) {
    state.environmentsLoading = false;
    state.environments = [];
  },

  /**
   * Individual panel/metric results
   */
  [types.REQUEST_METRIC_RESULT](state, { metricId }) {
    const metric = findMetricInDashboard(metricId, state.dashboard);
    setMetricState(metric, {
      loading: true,
      state: metricStates.LOADING,
    });
  },
  [types.RECEIVE_METRIC_RESULT_SUCCESS](state, { metricId, result }) {
    if (!metricId) {
      return;
    }

    state.showEmptyState = false;

    const metric = findMetricInDashboard(metricId, state.dashboard);
    if (!result || result.length === 0) {
      setMetricState(metric, {
        state: metricStates.NO_DATA,
      });
    } else {
      const normalizedResults = result.map(normalizeQueryResult);
      setMetricState(metric, {
        result: Object.freeze(normalizedResults),
        state: metricStates.OK,
      });
    }
  },
  [types.RECEIVE_METRIC_RESULT_FAILURE](state, { metricId, error }) {
    if (!metricId) {
      return;
    }
    const metric = findMetricInDashboard(metricId, state.dashboard);
    setMetricState(metric, {
      state: emptyStateFromError(error),
    });
  },

  [types.SET_ENDPOINTS](state, endpoints) {
    state.metricsEndpoint = endpoints.metricsEndpoint;
    state.deploymentsEndpoint = endpoints.deploymentsEndpoint;
    state.dashboardEndpoint = endpoints.dashboardEndpoint;
    state.dashboardsEndpoint = endpoints.dashboardsEndpoint;
    state.currentDashboard = endpoints.currentDashboard;
    state.projectPath = endpoints.projectPath;
  },
  [types.SET_GETTING_STARTED_EMPTY_STATE](state) {
    state.emptyState = 'gettingStarted';
  },
  [types.SET_NO_DATA_EMPTY_STATE](state) {
    state.showEmptyState = true;
    state.emptyState = 'noData';
  },
  [types.SET_ALL_DASHBOARDS](state, dashboards) {
    state.allDashboards = dashboards || [];
  },
  [types.SET_SHOW_ERROR_BANNER](state, enabled) {
    state.showErrorBanner = enabled;
  },
  [types.SET_PANEL_GROUP_METRICS](state, payload) {
    const panelGroup = state.dashboard.panel_groups.find(pg => payload.key === pg.key);
    panelGroup.panels = payload.panels;
  },
  [types.SET_ENVIRONMENTS_FILTER](state, searchTerm) {
    state.environmentsSearchTerm = searchTerm;
  },
};
