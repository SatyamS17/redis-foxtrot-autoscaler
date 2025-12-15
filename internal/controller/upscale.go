package controller

import (
	"context"
	_ "embed"
	"fmt"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	appv1 "github.com/myuser/redis-operator/api/v1"
)

//go:embed scripts/reshard.sh
var reshardScript string

// checkReshardingStatus monitors the scale-up operation progress.
// It waits for pods to be ready, creates the reshard job if needed, and finalizes the scale-up
// by incrementing the master count and provisioning the next standby node.
func (r *RedisClusterReconciler) checkReshardingStatus(ctx context.Context, cluster *appv1.RedisCluster) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	sts := &appsv1.StatefulSet{}
	if err := r.Get(ctx, types.NamespacedName{Name: cluster.Name, Namespace: cluster.Namespace}, sts); err != nil {
		logger.Error(err, "Failed to get StatefulSet for reshard check")
		return ctrl.Result{}, err
	}

	desiredTotalReplicas := (cluster.Spec.Masters + 1) * (1 + cluster.Spec.ReplicasPerMaster)

	if *sts.Spec.Replicas != desiredTotalReplicas {
		logger.Info("Waiting for StatefulSet spec update",
			"current", *sts.Spec.Replicas,
			"desired", desiredTotalReplicas)
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}

	if sts.Status.ReadyReplicas != desiredTotalReplicas {
		logger.Info("Waiting for new pods to be ready",
			"ready", sts.Status.ReadyReplicas,
			"desired", desiredTotalReplicas)
		return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
	}

	logger.Info("All StatefulSet pods are ready, checking for reshard job")

	reshardJob := &batchv1.Job{}
	jobName := cluster.Name + "-reshard"
	err := r.Get(ctx, client.ObjectKey{Name: jobName, Namespace: cluster.Namespace}, reshardJob)

	if err != nil && errors.IsNotFound(err) {
		if sts.Status.ReadyReplicas != desiredTotalReplicas {
			logger.Info("Pods not ready yet, waiting before creating reshard job",
				"ready", sts.Status.ReadyReplicas,
				"desired", desiredTotalReplicas)
			return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
		}

		logger.Info("Creating reshard job to activate standby",
			"overloadedPod", cluster.Status.OverloadedPod,
			"standbyPod", cluster.Status.StandbyPod)

		if cluster.Status.OverloadedPod == "" {
			logger.Error(fmt.Errorf("overloadedPod is empty"), "Cannot create reshard job without overloaded pod")
			cluster.Status.IsResharding = false
			_ = r.Status().Update(ctx, cluster)
			return ctrl.Result{}, nil
		}

		if cluster.Status.StandbyPod == "" {
			logger.Error(fmt.Errorf("standbyPod is empty"), "Cannot create reshard job without standby pod")
			cluster.Status.IsResharding = false
			_ = r.Status().Update(ctx, cluster)
			return ctrl.Result{}, nil
		}

		job := r.reshardJobForRedisCluster(cluster, cluster.Status.OverloadedPod, cluster.Status.StandbyPod)
		if err := controllerutil.SetControllerReference(cluster, job, r.Scheme); err != nil {
			logger.Error(err, "Failed to set owner reference on reshard job")
			return ctrl.Result{}, err
		}
		if err := r.Create(ctx, job); err != nil {
			logger.Error(err, "Failed to create reshard job")
			return ctrl.Result{}, err
		}
		return ctrl.Result{Requeue: true}, nil

	} else if err != nil {
		logger.Error(err, "Failed to get reshard job")
		return ctrl.Result{}, err
	}

	if reshardJob.Status.Succeeded > 0 {
		logger.Info("Reshard job succeeded, provisioning next standby pods")

		cluster.Spec.Masters++
		if err := r.Update(ctx, cluster); err != nil {
			logger.Error(err, "Failed to update spec to increment masters")
			return ctrl.Result{}, err
		}

		sts := r.statefulSetForRedisCluster(cluster)
		logger.Info("Triggering StatefulSet update to provision next standby")
		if err := r.reconcileStatefulSet(ctx, cluster, sts); err != nil {
			logger.Error(err, "Failed to reconcile StatefulSet to provision next standby")
		}

		// Transition to provisioning state - need to add new pods to cluster
		cluster.Status.IsResharding = false
		cluster.Status.IsProvisioningStandby = true
		cluster.Status.OverloadedPod = ""
		now := metav1.Now()
		cluster.Status.LastScaleTime = &now

		if err := r.Status().Update(ctx, cluster); err != nil {
			logger.Error(err, "Failed to update status after reshard")
			return ctrl.Result{}, err
		}

		_ = r.Delete(ctx, reshardJob, client.PropagationPolicy(metav1.DeletePropagationBackground))
		logger.Info("Transitioning to standby provisioning phase",
			"newMasters", cluster.Spec.Masters)

		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}

	if reshardJob.Status.Failed > 0 {
		logger.Error(fmt.Errorf("reshard job %s failed", jobName), "Resharding failed")
		// Clean up the failed job to allow a retry
		_ = r.Delete(ctx, reshardJob, client.PropagationPolicy(metav1.DeletePropagationBackground))
		cluster.Status.IsResharding = false
		cluster.Status.OverloadedPod = ""
		if err := r.Status().Update(ctx, cluster); err != nil {
			logger.Error(err, "Failed to update status after failed reshard")
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: 1 * time.Second}, nil
	}

	logger.Info("Reshard job is still running...")
	return ctrl.Result{RequeueAfter: 15 * time.Second}, nil
}

// reshardJobForRedisCluster creates a Kubernetes Job that performs the scale-up resharding.
// It activates the standby pod by moving half the slots from the overloaded pod to it.
// The job uses redis-cli to fix cluster health, verify the standby, and perform the slot migration.
func (r *RedisClusterReconciler) reshardJobForRedisCluster(cluster *appv1.RedisCluster, overloadedPod string, standbyPod string) *batchv1.Job {
	anyPodHost := fmt.Sprintf("%s-0.%s.%s.svc.cluster.local",
		cluster.Name, cluster.Name+"-headless", cluster.Namespace)
	anyPodPort := "6379"
	entrypoint := fmt.Sprintf("%s:%s", anyPodHost, anyPodPort)

	timeout := int64(cluster.Spec.ReshardTimeoutSeconds)
	backoff := int32(0)

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cluster.Name + "-reshard",
			Namespace: cluster.Namespace,
			Labels:    getLabels(cluster),
		},
		Spec: batchv1.JobSpec{
			ActiveDeadlineSeconds: &timeout,
			BackoffLimit:          &backoff,
			Template: corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers: []corev1.Container{
						{
							Name:    "smart-reshard",
							Image:   fmt.Sprintf("redis:%s", cluster.Spec.RedisVersion),
							Command: []string{"sh", "-c"},
							Args:    []string{reshardScript},
							Env: []corev1.EnvVar{
								{Name: "ANY_POD_HOST", Value: anyPodHost},
								{Name: "ANY_POD_PORT", Value: anyPodPort},
								{Name: "ANY_POD_ENTRYPOINT", Value: entrypoint},
								{Name: "OVERLOADED_POD", Value: overloadedPod},
								{Name: "STANDBY_POD", Value: standbyPod},
								{Name: "CLUSTER_NAME", Value: cluster.Name},
								{Name: "SERVICE_NAME", Value: cluster.Name + "-headless"},
								{Name: "NAMESPACE", Value: cluster.Namespace},
							},
						},
					},
				},
			},
		},
	}
}
