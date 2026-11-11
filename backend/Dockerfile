# Stage 1: the full SDK compiles the code. This stage is thrown away afterwards.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore the packages first, on their own. Docker reuses this layer until the project file changes,
# so a code-only change does not download the packages again.
COPY src/Api/Api.csproj src/Api/
RUN dotnet restore src/Api/Api.csproj

COPY src/ src/
RUN dotnet publish src/Api/Api.csproj -c Release -o /app --no-restore

# Stage 2: only the small runtime and the compiled output. No SDK, no source code.
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

# Do not run as root inside the container. The image provides this unprivileged user.
USER $APP_UID

# The .NET images listen on port 8080 by default.
EXPOSE 8080
ENTRYPOINT ["dotnet", "Api.dll"]
