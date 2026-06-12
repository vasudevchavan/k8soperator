/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"

	appsv1alpha1 "github.com/vasudevchavan/k8soperator/api/v1alpha1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	webAppName = "web-application"
	dbAppName  = "data-db"

	ConditionWebAppReady = "WebAppReady"
	ConditionDBReady     = "DBReady"
	ConditionAvailable   = "Available"
)

// setCondition updates or adds a condition to the CR status.
// It returns true if the status, reason, or message of the condition has changed.
func setCondition(cr *appsv1alpha1.K8soperator, condition metav1.Condition) bool {
	for i, cond := range cr.Status.Conditions {
		if cond.Type == condition.Type {
			if cond.Status == condition.Status && cond.Reason == condition.Reason && cond.Message == condition.Message {
				return false
			}
			if cond.Status == condition.Status {
				condition.LastTransitionTime = cond.LastTransitionTime
			} else {
				condition.LastTransitionTime = metav1.Now()
			}
			cr.Status.Conditions[i] = condition
			return true
		}
	}
	condition.LastTransitionTime = metav1.Now()
	cr.Status.Conditions = append(cr.Status.Conditions, condition)
	return true
}

// K8soperatorReconciler reconciles a K8soperator object
type K8soperatorReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=apps.mydomain.com,resources=k8soperators,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps.mydomain.com,resources=k8soperators/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps.mydomain.com,resources=k8soperators/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=coordination.k8s.io,resources=leases,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch;update;get;list;watch

func (r *K8soperatorReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	log.Info("Reconciling K8soperator", "namespacedName", req.NamespacedName)

	var k8soperator appsv1alpha1.K8soperator
	if err := r.Get(ctx, req.NamespacedName, &k8soperator); err != nil {
		if errors.IsNotFound(err) {
			log.Info("K8soperator resource not found, ignoring")
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	statusChanged := false

	// Honor maintenanceMode: if set, skip active reconciliation and surface a condition.
	if k8soperator.Spec.MaintenanceMode {
		log.Info("maintenance mode enabled; skipping reconciliation", "namespacedName", req.NamespacedName)

		if setCondition(&k8soperator, metav1.Condition{
			Type:    "Maintenance",
			Status:  metav1.ConditionTrue,
			Reason:  "MaintenanceModeEnabled",
			Message: "Reconciliation suspended while maintenanceMode is true",
		}) {
			statusChanged = true
		}

		if statusChanged {
			if err := r.Status().Update(ctx, &k8soperator); err != nil {
				log.Error(err, "unable to update K8soperator status while setting Maintenance condition")
				return ctrl.Result{}, err
			}
		}

		return ctrl.Result{}, nil
	}

	// Ensure Maintenance condition is set to False if it was previously True
	if setCondition(&k8soperator, metav1.Condition{
		Type:    "Maintenance",
		Status:  metav1.ConditionFalse,
		Reason:  "MaintenanceModeDisabled",
		Message: "Reconciliation is active",
	}) {
		statusChanged = true
	}

	replicas := k8soperator.Spec.Replicas
	if replicas == 0 {
		replicas = 1
	}
	log.Info("Using replicas", "specReplicas", k8soperator.Spec.Replicas, "finalReplicas", replicas)

	// Create/update web app deployment
	webAppDeployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webAppName,
			Namespace: k8soperator.Namespace,
		},
	}

	result, err := controllerutil.CreateOrUpdate(ctx, r.Client, webAppDeployment, func() error {
		webAppDeployment.Spec = appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": webAppName},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": webAppName},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{{
						Name:  webAppName,
						Image: "nginx:latest",
					}},
				},
			},
		}
		return controllerutil.SetControllerReference(&k8soperator, webAppDeployment, r.Scheme)
	})
	log.Info("Web app deployment", "result", result)
	if err != nil {
		log.Error(err, "Failed to create or update web app deployment")
		return ctrl.Result{}, err
	}

	// Create/update web app service
	webAppService := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webAppName,
			Namespace: k8soperator.Namespace,
		},
	}

	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, webAppService, func() error {
		webAppService.Spec = corev1.ServiceSpec{
			Type: corev1.ServiceTypeNodePort,
			Selector: map[string]string{
				"app": webAppName,
			},
			Ports: []corev1.ServicePort{{
				Port:       80,
				Protocol:   corev1.ProtocolTCP,
				TargetPort: intstr.FromInt(80),
				NodePort:   30080,
			}},
		}
		return controllerutil.SetControllerReference(&k8soperator, webAppService, r.Scheme)
	})
	if err != nil {
		log.Error(err, "Failed to create or update web app service")
		return ctrl.Result{}, err
	}

	// Create/update DB deployment
	dbDeployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      dbAppName,
			Namespace: k8soperator.Namespace,
		},
	}

	result, err = controllerutil.CreateOrUpdate(ctx, r.Client, dbDeployment, func() error {
		dbDeployment.Spec = appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": dbAppName},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": dbAppName},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{{
						Name:  "db",
						Image: "nginx:latest",
					}},
				},
			},
		}
		return controllerutil.SetControllerReference(&k8soperator, dbDeployment, r.Scheme)
	})
	log.Info("DB deployment", "result", result)
	if err != nil {
		log.Error(err, "Failed to create or update DB deployment")
		return ctrl.Result{}, err
	}

	// Check deployment readiness and update conditions

	// Web app deployment status
	var webStatus appsv1.Deployment
	err = r.Get(ctx, client.ObjectKey{Name: webAppName, Namespace: k8soperator.Namespace}, &webStatus)
	if err == nil && webStatus.Status.ReadyReplicas >= replicas {
		if setCondition(&k8soperator, metav1.Condition{
			Type:    ConditionWebAppReady,
			Status:  metav1.ConditionTrue,
			Reason:  "DeploymentReady",
			Message: "Web application is ready",
		}) {
			statusChanged = true
		}
	} else {
		if setCondition(&k8soperator, metav1.Condition{
			Type:    ConditionWebAppReady,
			Status:  metav1.ConditionFalse,
			Reason:  "NotReady",
			Message: "Web application is not ready",
		}) {
			statusChanged = true
		}
	}

	// DB deployment status
	var dbStatus appsv1.Deployment
	err = r.Get(ctx, client.ObjectKey{Name: dbAppName, Namespace: k8soperator.Namespace}, &dbStatus)
	if err == nil && dbStatus.Status.ReadyReplicas >= replicas {
		if setCondition(&k8soperator, metav1.Condition{
			Type:    ConditionDBReady,
			Status:  metav1.ConditionTrue,
			Reason:  "DeploymentReady",
			Message: "Database is ready",
		}) {
			statusChanged = true
		}
	} else {
		if setCondition(&k8soperator, metav1.Condition{
			Type:    ConditionDBReady,
			Status:  metav1.ConditionFalse,
			Reason:  "NotReady",
			Message: "Database is not ready",
		}) {
			statusChanged = true
		}
	}

	// Overall Available condition
	webReady := false
	dbReady := false
	for _, cond := range k8soperator.Status.Conditions {
		if cond.Type == ConditionWebAppReady && cond.Status == metav1.ConditionTrue {
			webReady = true
		}
		if cond.Type == ConditionDBReady && cond.Status == metav1.ConditionTrue {
			dbReady = true
		}
	}
	if webReady && dbReady {
		if setCondition(&k8soperator, metav1.Condition{
			Type:    ConditionAvailable,
			Status:  metav1.ConditionTrue,
			Reason:  "ComponentsReady",
			Message: "Both web app and database are ready",
		}) {
			statusChanged = true
		}
	} else {
		if setCondition(&k8soperator, metav1.Condition{
			Type:    ConditionAvailable,
			Status:  metav1.ConditionFalse,
			Reason:  "WaitingForComponents",
			Message: "Waiting for one or more components to become ready",
		}) {
			statusChanged = true
		}
	}

	// Update the status subresource
	if statusChanged {
		if err := r.Status().Update(ctx, &k8soperator); err != nil {
			log.Error(err, "unable to update K8soperator status")
			return ctrl.Result{}, err
		}
	}

	log.Info("Reconciliation completed successfully")
	return ctrl.Result{}, nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *K8soperatorReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&appsv1alpha1.K8soperator{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Complete(r)
}
