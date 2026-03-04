import kotlin.math.atan
import kotlin.math.PI
//TIP To <b>Run</b> code, press <shortcut actionId="Run"/> or
// click the <icon src="AllIcons.Actions.Execute"/> icon in the gutter.

fun main() {
        print("Enter student name: ")
        val name = readLine() ?: "Unknown"

        print("Enter number of grades: ")
        val numGrades = readLine()?.toIntOrNull() ?: 0

        val grades = mutableListOf<Double>()
        for (i in 1..numGrades) {
            print("Enter grade #$i: ")
            val grade = readLine()?.toDoubleOrNull()
            if (grade != null && grade in 0.0..100.0) {
                grades.add(grade)
            } else {
                println("Invalid grade! It will be ignored.")
            }
        }
        if (grades.isEmpty()) {
            println("No valid grades entered. Cannot compute average.")
            return
        }
        var sum = 0.0
        for (grade in grades) {
            sum += grade
        }
        val average = sum / grades.size

        println("Student: $name")
        println("Grades: $grades")
        println("Average: ${"%.2f".format(average)}")

        val performance = when {
            average >= 90 -> "A"
            average >= 75 -> "B"
            average >= 60 -> "C"
            else -> "F"
        }

        println("Performance: $performance")
    }


