## self documenting help target

```makefile
help:           ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36mmake %-18s\033[0m \033[2;37m%s\033[0m\n", $$1, $$2}'
```