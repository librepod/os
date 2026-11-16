package v1alpha1

import (
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// DeviceSpec holds the owner's answers. Each section is acted on once, when
// its rev/id is above status.handled.<section>.
type DeviceSpec struct {
	Updates *UpdatesSpec `json:"updates,omitempty"`
	Install *InstallSpec `json:"install,omitempty"`
	Power   *PowerSpec   `json:"power,omitempty"`
	SSHKeys *SSHKeysSpec `json:"sshKeys,omitempty"`
}

type UpdatesSpec struct {
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=999999999999999
	Rev int64 `json:"rev"`
	// +kubebuilder:validation:Enum=stable;beta
	Channel string `json:"channel"`
	Auto    bool   `json:"auto"`
	// +kubebuilder:validation:MaxLength=64
	// +kubebuilder:validation:Pattern=`^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$`
	Timezone string `json:"timezone"`
}

type InstallSpec struct {
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=999999999999999
	ID int64 `json:"id"`
	// +kubebuilder:validation:Enum=now;tonight
	When string `json:"when"`
}

type PowerSpec struct {
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=999999999999999
	ID int64 `json:"id"`
	// +kubebuilder:validation:Enum=reboot;poweroff
	Action string `json:"action"`
}

type SSHKeysSpec struct {
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=999999999999999
	Rev int64 `json:"rev"`
	// +kubebuilder:validation:MaxItems=32
	// +kubebuilder:validation:items:MaxLength=8192
	// +kubebuilder:validation:items:Pattern=`^[a-z0-9@.-]+ AAAA[A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$`
	Keys []string `json:"keys"`
}

// Handled is the last number acted on, per section.
type Handled struct {
	Updates int64 `json:"updates"`
	Install int64 `json:"install"`
	Power   int64 `json:"power"`
	SSHKeys int64 `json:"sshKeys"`
}

type Disk struct {
	SizeBytes int64 `json:"sizeBytes"`
	UsedBytes int64 `json:"usedBytes"`
}

type DataDisk struct {
	Present   bool  `json:"present"`
	SizeBytes int64 `json:"sizeBytes,omitempty"`
	UsedBytes int64 `json:"usedBytes,omitempty"`
}

type SystemStatus struct {
	Version  string   `json:"version"`
	RootDisk Disk     `json:"rootDisk"`
	DataDisk DataDisk `json:"dataDisk"`
}

type DeviceStatus struct {
	Updated  *metav1.Time      `json:"updated,omitempty"`
	Handled  Handled           `json:"handled"`
	Rejected map[string]string `json:"rejected,omitempty"`
	// Update is the updater's status.json, verbatim: the updater owns its schema.
	// +kubebuilder:pruning:PreserveUnknownFields
	// +kubebuilder:validation:Type=object
	Update        *apiextensionsv1.JSON `json:"update,omitempty"`
	SSHKeys       []string              `json:"sshKeys"`
	System        *SystemStatus         `json:"system,omitempty"`
	SetupCodeHash string                `json:"setupCodeHash,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,shortName=dev
type Device struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   DeviceSpec   `json:"spec,omitempty"`
	Status DeviceStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type DeviceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Device `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Device{}, &DeviceList{})
}
