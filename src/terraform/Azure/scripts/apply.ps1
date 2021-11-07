$serviceName = "aadlicense"
$environment = "dev"

terraform apply -input=false `
    -auto-approve `
    -var="service_name=${serviceName}" `
    -var-file=".\config\${serviceName}.tfvars" `
    -var-file=".\config\${environment}.tfvars"