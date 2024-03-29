# Преобразование логов http accesslog в метрики с vector.dev

В данном каталоге лежат файлы описывающий подход, позволяющий генерировать метрики из логов без переписывания кода трансформов под каждый сервис.

1. Полагаемся на то, что все сервисы пишут логи в фиксированном формате JSON и имеют одинаковый набор обязательных полей. См. [example_logs]
2. Для кодогенерации использован Ansible и jinja2 шаблоны. Генерируем toml файлы конфигурации vector.dev и тесты к ним, где нужно.
3. Метрики определяются в файле [ansible-playbook/vars/metrics-catalog.yml], после этого запускаем генерацию через ansible. См пример в Makefile
4. Отдельной задачей конфигурации выгружаются на серверы с агрегаторами vector.dev, и для применения новой конфигурации выполняется перезапуск процесса vector

## Что нам дал рефакторинг

* Мы вместо 5 часов теперь тратим 10-30 минут на добавление/изменение метрик с учетом выкатки на прод
* Появилась автоматическая валидация по схеме, теперь ошибку при описании метрки допустить сложнее
* Теперь для добавления новой метрки не нужно знать как это закодировать на языку VRL - достаточно YAML девелопера )


## Ограничения

Данный код является ознакомительным и не представляет собой готовое решение, вы можете придумать свое на основе данных идей.
Потому мы не приводим полные конфигурации vector.dev, код развертывания и полный набор ansible файлов для playbook.
Однако вы можете сгенерировать по файлу [ansible-playbook/vars/metrics-catalog.yml] файлы конфигурации vector и посмотреть как они выглядят.

## Генерирование файлов конфигурации

1. Используйте Ubuntu Linux (или Debian)
2. Запустите `make install-dependencies` и `make install-dev-dependencies`
3. Запустите `make download-vector-bin` - установить файлы vector для валидации запуска тестов
4. Выполните сборку и тесты `make test-vector-transfroms`
5. Созданные файлы смотрите в каталоге [.generated/vector_config]

## Контакты

Если вам интересны подробности вы можете писать нам, см. сайт https://vitech.team/ ("По вопросам сотрудничества") или приходите работать к нам.
