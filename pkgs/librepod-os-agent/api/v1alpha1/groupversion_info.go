// Package v1alpha1 is the Device API: the one object through which the
// Marketplace and the OS agent talk. See docs/updates.md.
// +kubebuilder:object:generate=true
// +groupName=os.librepod.org
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	GroupVersion = schema.GroupVersion{Group: "os.librepod.org", Version: "v1alpha1"}

	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	AddToScheme = SchemeBuilder.AddToScheme
)
