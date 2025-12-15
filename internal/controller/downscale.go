package controller

import (
	"context"
	_ "embed"
	"fmt"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	appv1 "github.com/myuser/redis-operator/api/v1"
)

//go:embed scripts/drain.sh
var drainScript string

//go:embed scripts/cleanup-standby.sh
var cleanupStandbyScript string

// checkDrainStatus monitors the scale-down operation progress.
// It creates the drain job if needed, monitors its progress, and finalizes the scale-down
// by decrementing the master count and updating the standby pod reference.
func (r *RedisClusterReconciler) checkDrainStatus(ctx context.Context, cluster *appv1.RedisCluster) (ctrl.Result, error) {
	logger := log.FromContext(ctx)
	jobName := cluster.Name + "-drain"

	drainJob := &batchv1.Job{}
	err := r.Get(ctx, client.ObjectKey{Name: jobName, Namespace: cluster.Namespace}, drainJob)

	if err != nil && errors.IsNotFound(err) {
		podName := cluster.Status.PodToDrain
		destPod1 := cluster.Status.DrainDestPod1
		destPod2 := cluster.Status.DrainDestPod2

		if podName == "" || destPod1 == "" {
			logger.Error(fmt.Errorf("IsDraining is true but drain info is incomplete"), "State error")
			cluster.Status.IsDraining = false
			cluster.Status.PodToDrain = ""
			cluster.Status.DrainDestPod1 = ""
			cluster.Status.DrainDestPod2 = ""
			_ = r.Status().Update(ctx, cluster)
			return ctrl.Result{}, nil
		}

		if podName == cluster.Status.StandbyPod {
			logger.Error(fmt.Errorf("attempted to drain standby pod"), "Invalid operation",
				"standbyPod", cluster.Status.StandbyPod)
			cluster.Status.IsDraining = false
			cluster.Status.PodToDrain = ""
			cluster.Status.DrainDestPod1 = ""
			cluster.Status.DrainDestPod2 = ""
			_ = r.Status().Update(ctx, cluster)
			return ctrl.Result{}, nil
		}

		logger.Info("Creating drain job",
			"pod", podName,
			"dest1", destPod1,
			"dest2", destPod2)

		job := r.drainJobForRedisCluster(cluster, podName, destPod1, destPod2)
		if err := controllerutil.SetControllerReference(cluster, job, r.Scheme); err != nil {
			logger.Error(err, "Failed to set owner reference on drain job")
			return ctrl.Result{}, err
		}
		if err := r.Create(ctx, job); err != nil {
			logger.Error(err, "Failed to create drain job")
			return ctrl.Result{}, err
		}
		return ctrl.Result{Requeue: true}, nil

	} else if err != nil {
		logger.Error(err, "Failed to get drain job")
		return ctrl.Result{}, err
	}

	if drainJob.Status.Succeeded > 0 {
		logger.Info("Drain job succeeded, pod is empty, removing old standby from cluster")

		drainedPod := cluster.Status.PodToDrain
		oldStandby := cluster.Status.StandbyPod

		// Check if cleanup job exists to remove old standby from cluster
		cleanupJobName := cluster.Name + "-cleanup-standby"
		cleanupJob := &batchv1.Job{}
		err := r.Get(ctx, client.ObjectKey{Name: cleanupJobName, Namespace: cluster.Namespace}, cleanupJob)

		if err != nil && errors.IsNotFound(err) {
			logger.Info("Creating cleanup job to remove old standby from cluster",
				"oldStandby", oldStandby,
				"drainedPod", drainedPod)

			job := r.cleanupStandbyJobForRedisCluster(cluster, oldStandby, drainedPod)
			if err := controllerutil.SetControllerReference(cluster, job, r.Scheme); err != nil {
				logger.Error(err, "Failed to set owner reference on cleanup job")
				return ctrl.Result{}, err
			}
			if err := r.Create(ctx, job); err != nil {
				logger.Error(err, "Failed to create cleanup job")
				return ctrl.Result{}, err
			}
			return ctrl.Result{RequeueAfter: 5 * time.Second}, nil

		} else if err != nil {
			logger.Error(err, "Failed to get cleanup job")
			return ctrl.Result{}, err
		}

		// Wait for cleanup job to complete
		if cleanupJob.Status.Succeeded == 0 && cleanupJob.Status.Failed == 0 {
			logger.Info("Cleanup job is still running, waiting...")
			return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
		}

		if cleanupJob.Status.Failed > 0 {
			logger.Error(fmt.Errorf("cleanup job failed"), "Failed to remove old standby from cluster")
			// Clean up the failed job to allow retry
			_ = r.Delete(ctx, cleanupJob, client.PropagationPolicy(metav1.DeletePropagationBackground))
			return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
		}

		// Cleanup job succeeded - now safe to scale down StatefulSet
		logger.Info("Cleanup job succeeded, old standby removed from cluster, scaling down StatefulSet")

		// Decrement masters count
		cluster.Spec.Masters--
		if err := r.Update(ctx, cluster); err != nil {
			logger.Error(err, "Failed to update spec to decrease masters after drain")
			return ctrl.Result{}, err
		}

		// Scale down StatefulSet to remove old standby pod
		// The StatefulSet will delete the highest-index pod (the old standby)
		sts := r.statefulSetForRedisCluster(cluster)
		logger.Info("Scaling down StatefulSet to remove old standby",
			"oldStandby", oldStandby,
			"newStandby", drainedPod)
		if err := r.reconcileStatefulSet(ctx, cluster, sts); err != nil {
			logger.Error(err, "Failed to reconcile StatefulSet after scale-down")
		}

		// Drained pod becomes the new standby
		cluster.Status.StandbyPod = drainedPod

		cluster.Status.IsDraining = false
		cluster.Status.PodToDrain = ""
		cluster.Status.DrainDestPod1 = ""
		cluster.Status.DrainDestPod2 = ""
		now := metav1.Now()
		cluster.Status.LastScaleTime = &now

		if err := r.Status().Update(ctx, cluster); err != nil {
			logger.Error(err, "Failed to update status after drain")
			return ctrl.Result{}, err
		}

		_ = r.Delete(ctx, drainJob, client.PropagationPolicy(metav1.DeletePropagationBackground))
		_ = r.Delete(ctx, cleanupJob, client.PropagationPolicy(metav1.DeletePropagationBackground))

		logger.Info("Scale-down complete, StatefulSet will delete old standby pods",
			"newMasters", cluster.Spec.Masters,
			"oldStandby", oldStandby,
			"newStandby", drainedPod)
		return ctrl.Result{}, nil
	}

	if drainJob.Status.Failed > 0 {
		logger.Error(fmt.Errorf("drain job %s failed", jobName), "Draining failed")
		_ = r.Delete(ctx, drainJob, client.PropagationPolicy(metav1.DeletePropagationBackground))
		cluster.Status.IsDraining = false
		cluster.Status.PodToDrain = ""
		cluster.Status.DrainDestPod1 = ""
		cluster.Status.DrainDestPod2 = ""
		if err := r.Status().Update(ctx, cluster); err != nil {
			logger.Error(err, "Failed to update status after failed drain")
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: 1 * time.Second}, nil
	}

	logger.Info("Drain job is still running")
	return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

// drainJobForRedisCluster creates a Kubernetes Job that performs the scale-down draining.
// It uses pre-seeding via replication to speed up the migration, then moves slots from the
// drained pod to the destination pod(s). The drained pod becomes the new standby.
func (r *RedisClusterReconciler) drainJobForRedisCluster(
	cluster *appv1.RedisCluster,
	podToDrain string,
	destPod1 string,
	destPod2 string,
) *batchv1.Job {
	anyPodHost := fmt.Sprintf("%s-0.%s.%s.svc.cluster.local",
		cluster.Name, cluster.Name+"-headless", cluster.Namespace)
	entrypoint := fmt.Sprintf("%s:6379", anyPodHost)

	timeout := int64(cluster.Spec.ReshardTimeoutSeconds)
	backoff := int32(0)

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cluster.Name + "-drain",
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
							Name:    "smart-drain",
							Image:   fmt.Sprintf("redis:%s", cluster.Spec.RedisVersion),
							Command: []string{"sh", "-c"},
							Args:    []string{drainScript},
							Env: []corev1.EnvVar{
								{Name: "POD_TO_DRAIN", Value: podToDrain},
								{Name: "DEST_POD_1", Value: destPod1},
								{Name: "DEST_POD_2", Value: destPod2},
								{Name: "STANDBY_POD", Value: cluster.Status.StandbyPod},
								{Name: "SERVICE_NAME", Value: cluster.Name + "-headless"},
								{Name: "NAMESPACE", Value: cluster.Namespace},
								{Name: "ENTRYPOINT_HOST", Value: anyPodHost},
								{Name: "ENTRYPOINT_WITH_PORT", Value: entrypoint},
							},
						},
					},
				},
			},
		},
	}
}

// cleanupStandbyJobForRedisCluster creates a Kubernetes Job that removes the old standby pods from the Redis cluster.
// This job removes both the new standby (drained pod + replicas) and old standby (previous standby + replicas),
// then re-adds the new standby pods fresh to the cluster.
func (r *RedisClusterReconciler) cleanupStandbyJobForRedisCluster(cluster *appv1.RedisCluster, standbyPod string, drainedPod string) *batchv1.Job {
	anyPodHost := fmt.Sprintf("%s-0.%s.%s.svc.cluster.local",
		cluster.Name, cluster.Name+"-headless", cluster.Namespace)
	entrypoint := fmt.Sprintf("%s:6379", anyPodHost)

	// Calculate indices
	newStandbyIndex := (cluster.Spec.Masters - 1) * (1 + cluster.Spec.ReplicasPerMaster)
	oldStandbyIndex := cluster.Spec.Masters * (1 + cluster.Spec.ReplicasPerMaster)

	timeout := int64(300) // 5 minutes should be enough
	backoff := int32(3)

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cluster.Name + "-cleanup-standby",
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
							Name:    "cleanup-standby",
							Image:   fmt.Sprintf("redis:%s", cluster.Spec.RedisVersion),
							Command: []string{"sh", "-c"},
							Args:    []string{cleanupStandbyScript},
							Env: []corev1.EnvVar{
								{Name: "CLUSTER_NAME", Value: cluster.Name},
								{Name: "SERVICE_NAME", Value: cluster.Name + "-headless"},
								{Name: "NAMESPACE", Value: cluster.Namespace},
								{Name: "ENTRYPOINT_HOST", Value: anyPodHost},
								{Name: "ENTRYPOINT_WITH_PORT", Value: entrypoint},
								{Name: "REPLICAS_PER_MASTER", Value: fmt.Sprintf("%d", cluster.Spec.ReplicasPerMaster)},
								{Name: "NEW_STANDBY_INDEX", Value: fmt.Sprintf("%d", newStandbyIndex)},
								{Name: "OLD_STANDBY_INDEX", Value: fmt.Sprintf("%d", oldStandbyIndex)},
							},
						},
					},
				},
			},
		},
	}
}
