# Use intermediate container to protect Azure secret info from published image
# Otherwise there will be traces of the client id and key in the layers of the
# image.

# mvn -DskipTests is used below for convenience of this example.  If you want to run 
# actual tests you will need to setup a KeyVault and store the following information 
# in it that references redis and mysql hen refence that Keyvault as shown below

# spring-datasource-password
# spring-datasource-url
# spring-datasource-username
# spring-redis-host
# spring-redis-password

# Pass --build-args for the following KEYVAULT_URL, KEYVAULT_CLIENT_ID, and KEYVAULT_CLIENT_KEY
# This is the Keyvault info for where your MySQL connection string, MySQL username
# and password are stored

# Example Command
# docker build --build-arg KEYVAULT_URL=${KEYVAULT_URL} --build-arg KEYVAULT_CLIENT_ID=${KEYVAULT_CLIENT_ID} --build-arg KEYVAULT_CLIENT_KEY=${KEYVAULT_CLIENT_KEY} --build-arg KEYVAULT_TENANT_ID=${KEYVAULT_TENANT_ID} .

# Make sure before running the above you have the following ENV variables...
# KEYVAULT_CLIENT_ID
# KEYVAULT_CLIENT_KEY
# KEYVAULT_URL
# KEYVAULT_TENANT_ID

FROM maven:3.6.2-jdk-8 as BUILD
ARG KEYVAULT_URL
ENV KEYVAULT_URL=$KEYVAULT_URL
ARG KEYVAULT_CLIENT_ID
ENV KEYVAULT_CLIENT_ID=$KEYVAULT_CLIENT_ID
ARG KEYVAULT_CLIENT_KEY
ENV KEYVAULT_CLIENT_KEY=$KEYVAULT_CLIENT_KEY
COPY . /usr/src/app
RUN mvn --batch-mode -f /usr/src/app/pom.xml clean package -DskipTests

#FROM openjdk:8u232-slim
FROM openjdk:8u232-jre-slim
ENV PORT 8080
EXPOSE 8080
COPY --from=BUILD /usr/src/app/target /opt/target
WORKDIR /opt/target

CMD ["/bin/bash", "-c", "find -type f -name 'todo*.jar' | xargs java -jar"]
