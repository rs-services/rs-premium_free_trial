name "LIB - Common parameters"
rs_ca_ver 20160108
short_description "Parameters that are commonly used across multiple CATs"

package "common/parameters"

parameter "param_location" do 
  category "Deployment Options"
  label "Cloud" 
  type "string" 
  allowed_values "AWS", "Azure", "Google", "VMware" 
  default "Google"
end

parameter "param_costcenter" do 
  category "Deployment Options"
  label "Cost Center" 
  type "string" 
  allowed_values "Development", "QA", "Production"
  default "Development"
end
