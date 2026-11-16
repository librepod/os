package v1alpha1

import (
	"os"
	"reflect"
	"testing"

	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"sigs.k8s.io/yaml"
)

func enumOf(p apiextensionsv1.JSONSchemaProps) []string {
	var out []string
	for _, e := range p.Enum {
		var s string
		_ = yaml.Unmarshal(e.Raw, &s)
		out = append(out, s)
	}
	return out
}

func TestCRDContract(t *testing.T) {
	raw, err := os.ReadFile("../../crd/os.librepod.org_devices.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var crd apiextensionsv1.CustomResourceDefinition
	if err := yaml.Unmarshal(raw, &crd); err != nil {
		t.Fatal(err)
	}
	if crd.Spec.Group != "os.librepod.org" || crd.Spec.Scope != apiextensionsv1.ClusterScoped ||
		crd.Spec.Names.Kind != "Device" || !reflect.DeepEqual(crd.Spec.Names.ShortNames, []string{"dev"}) {
		t.Fatalf("names/scope: %+v", crd.Spec)
	}
	if len(crd.Spec.Versions) != 1 {
		t.Fatalf("versions: %d", len(crd.Spec.Versions))
	}
	v := crd.Spec.Versions[0]
	if v.Name != "v1alpha1" || !v.Served || !v.Storage || v.Subresources == nil || v.Subresources.Status == nil {
		t.Fatalf("version: %+v", v)
	}
	root := v.Schema.OpenAPIV3Schema.Properties
	spec := root["spec"].Properties
	status := root["status"].Properties

	for _, c := range []struct{ sec, field string }{
		{"updates", "rev"}, {"sshKeys", "rev"}, {"install", "id"}, {"power", "id"},
	} {
		n := spec[c.sec].Properties[c.field]
		if n.Minimum == nil || *n.Minimum != 1 || n.Maximum == nil || *n.Maximum != 999999999999999 {
			t.Errorf("%s.%s bounds: %v %v", c.sec, c.field, n.Minimum, n.Maximum)
		}
	}
	for _, c := range []struct {
		sec, field string
		want       []string
	}{
		{"updates", "channel", []string{"stable", "beta"}},
		{"install", "when", []string{"now", "tonight"}},
		{"power", "action", []string{"reboot", "poweroff"}},
	} {
		if got := enumOf(spec[c.sec].Properties[c.field]); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s.%s enum: %v", c.sec, c.field, got)
		}
	}
	tz := spec["updates"].Properties["timezone"]
	if tz.Pattern != `^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$` || tz.MaxLength == nil || *tz.MaxLength != 64 {
		t.Errorf("timezone: %q %v", tz.Pattern, tz.MaxLength)
	}
	keys := spec["sshKeys"].Properties["keys"]
	it := keys.Items.Schema
	if keys.MaxItems == nil || *keys.MaxItems != 32 ||
		it.Pattern != `^[a-z0-9@.-]+ AAAA[A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$` || it.MaxLength == nil || *it.MaxLength != 8192 {
		t.Errorf("keys: %v %q %v", keys.MaxItems, it.Pattern, it.MaxLength)
	}
	for sec, want := range map[string][]string{
		"updates": {"rev", "channel", "auto", "timezone"},
		"install": {"id", "when"},
		"power":   {"id", "action"},
		"sshKeys": {"rev", "keys"},
	} {
		got := append([]string(nil), spec[sec].Required...)
		if len(got) != len(want) {
			t.Errorf("%s required: %v", sec, got)
			continue
		}
		set := map[string]bool{}
		for _, g := range got {
			set[g] = true
		}
		for _, w := range want {
			if !set[w] {
				t.Errorf("%s required misses %s: %v", sec, w, got)
			}
		}
	}
	if u := status["update"]; u.XPreserveUnknownFields == nil || !*u.XPreserveUnknownFields {
		t.Errorf("status.update must preserve unknown fields")
	}
}
