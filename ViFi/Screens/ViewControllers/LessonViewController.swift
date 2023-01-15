//
//  LessonViewController.swift
//  ViFi
//
//  Created by Emre Büyüker on 15.01.2023.
//

import UIKit
import Firebase
import FirebaseDatabase

class LessonViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    var uniName = String()
    var facName = String()
    var depName = String()
    var lessonName = String()
    var lessonsNameArray = [String]()
    
    @IBOutlet weak var lessonTableView: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.lessonTableView.delegate = self
        self.lessonTableView.dataSource = self
        
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
    }
    
    override func viewWillAppear(_ animated: Bool) {
        let tabBar = tabBarController as! BaseTabbarVC
        uniName = tabBar.uniNameVariable
        facName = tabBar.facNameVariable
        depName = tabBar.depNameVariable
        
        lessonsNameArray.removeAll()
        
        getDataFromFireBase()
    }
    
    @IBAction func HomaButtonClick(_ sender: Any) {
        self.tabBarController?.selectedIndex = 0
    }
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        
        dataBaseRefence.child("Universitiess").child(uniName).child(facName).child(depName).observe(DataEventType.childAdded) { (snapshot) in
            if (snapshot.key != "bolname" ) {
                self.lessonsNameArray.append(snapshot.key)
            }
            self.lessonTableView.reloadData()
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.lessonsNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = lessonTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! LessonTableViewCell
        if lessonsNameArray.count != 0 {
            cell.lessonNameLabel.text = lessonsNameArray[indexPath.row]
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        lessonName = lessonsNameArray[indexPath.row]
        performSegue(withIdentifier: "toExamVC", sender: nil)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "toExamVC" {
            let destinationVC = segue.destination as! ExamViewController
            destinationVC.lessonName = self.lessonName
        }
    }
}
