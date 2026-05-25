VERSION := $(shell cat version)
COLLECTION_DIR := $(DESTDIR)/usr/share/ansible/collections/ansible_collections/qubesos/setup

install:
	install -d $(COLLECTION_DIR)
	install -m 644 galaxy.yml $(COLLECTION_DIR)/galaxy.yml
	install -d $(COLLECTION_DIR)/meta
	install -m 644 meta/runtime.yml $(COLLECTION_DIR)/meta/runtime.yml
	cp -a roles $(COLLECTION_DIR)/roles
	cp -a playbooks $(COLLECTION_DIR)/playbooks
